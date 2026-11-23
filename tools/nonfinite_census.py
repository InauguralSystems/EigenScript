#!/usr/bin/env python3
"""Measure the treatment of IEEE non-finite values by an EigenScript binary."""
import argparse, collections, json, os, re, subprocess, sys, tempfile
from pathlib import Path

# Ordered: this is the single classifier table.  First matching expression wins.
CLASS_PATTERNS = (
    ("REFUSE", ("expected a finite number",)),
    ("NOINT", ("no integer representation",)),
    ("TRAP", ("non-finite arithmetic result", "not a number (NaN", "out of domain")),
)
EXCLUDED = ("clock_unix", "mktemp", "monotonic_ms", "monotonic_ns", "random",
            "random_hex", "exe_path", "getcwd")
VALUES = {"inf": "f64_from_bits of 9218868437227405312",
          "ninf": "f64_from_bits of -4503599627370496",
          "nan": "f64_from_bits of 9221120237041090560"}
MODES = (("unset", None), ("s0", "0"), ("s1", "1"))
NUM = re.compile(r"^-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?$")

def classify(output, rc):
    first = output.strip().splitlines()[0] if output.strip() else ""
    text = re.sub(r"^Error [^ ]+:\d+: ", "", first)
    for name, needles in CLASS_PATTERNS:
        if any(x in text for x in needles): return name
    if first.startswith("Error") or rc: return "ERR(" + text[:38] + ")"
    return "val(" + first[:22] + ")"

class Runner:
    def __init__(self, binary, timeout, allow_timeout):
        self.binary, self.timeout, self.allow = str(Path(binary).resolve()), timeout, allow_timeout
        self.tmp = tempfile.TemporaryDirectory(); self.timed_out = 0
    def run(self, program, mode=None):
        p = Path(self.tmp.name) / "probe.eigs"; p.write_text(program)
        env = dict(os.environ); env.pop("EIGS_STRICT", None)
        if mode is not None: env["EIGS_STRICT"] = mode
        try:
            r = subprocess.run([self.binary, str(p)], text=True, capture_output=True,
                               stdin=subprocess.DEVNULL, env=env, timeout=self.timeout)
        except subprocess.TimeoutExpired:
            self.timed_out += 1; return "TIMEOUT"
        out = r.stdout if r.returncode == 0 and r.stdout else r.stdout + r.stderr
        return classify(out, r.returncode)

def positions(args):
    result = []
    for i, raw in enumerate(args):
        a = raw.strip()
        if NUM.match(a): result.append((i, "scalar", "nf")); continue
        m = re.match(r"^\[\s*(-?\d+(?:\.\d+)?)\s*([,\]].*)$", a)
        if m: result.append((i, "elem", "[nf" + m.group(2))); continue
        m = re.match(r"^\[\s*\[\s*(-?\d+(?:\.\d+)?)\s*([,\]].*)$", a)
        if m: result.append((i, "elem2", "[[nf" + m.group(2)))
    return result

def cases(root): return json.loads((root / "tests/strict_shape_cases.json").read_text())
def call(name, args): return name + " of " + (args[0] if len(args) == 1 else "[" + ", ".join(args) + "]")

def write_tsv(path, header, rows):
    f = open(path, "w") if path else sys.stdout
    try:
        for line in header: f.write("# " + line + "\n")
        f.write("\t".join(rows[0]) + "\n")
        for row in rows[1:]: f.write("\t".join(map(str, row)) + "\n")
    finally:
        if path: f.close()

def summary(rows, runner, extra=""):
    counts = collections.Counter(cell.split("(",1)[0] for r in rows[1:] if r[4] != "control" for cell in r[-3:])
    control_errors=sum(1 for r in rows[1:] if r[4] == "control" and any(x.startswith("CONTROL_ERR(") for x in r[-3:]))
    if control_errors: counts["CONTROL_ERR"] = control_errors
    counts["TIMEOUT"] = runner.timed_out
    fields = [f"examined={len(rows)-1}"] + [f"{k}={counts[k]}" for k in sorted(counts)]
    print("summary " + " ".join(fields) + " excluded=" + ",".join(EXCLUDED) + (" " + extra if extra else ""))
    return 1 if len(rows) == 1 or (runner.timed_out and not runner.allow) else 0

def one_number(ns, root, run):
    names = sorted(set(re.findall(r"^\| `([a-z_0-9]+)` \|", (root/"docs/BUILTINS.md").read_text(), re.M)))
    rows = [("builtin","arg","kind","value","producer","unset","s0","s1")]
    for n in names:
        if n in EXCLUDED: continue
        finite = (run.run(f"print of ({n} of 2.5)\n"), run.run(f"print of ({n} of 2)\n"))
        if not any(x.startswith("val(") for x in finite): continue
        for vn, ve in VALUES.items():
            cells=[run.run(f"nf is {ve}\nprint of ({n} of nf)\n",m) for _,m in MODES]
            rows.append((n,"0","scalar",vn,"direct",*cells))
    write_tsv(ns.out, ["population: builtin names parsed from docs/BUILTINS.md table rows"], rows)
    return summary(rows,run)

def list_forms(ns, root, run):
    rows=[("builtin","arg","kind","value","producer","unset","s0","s1")]
    for c in cases(root):
        if c["name"] in EXCLUDED or c.get("requirements"): continue
        for i, kind, replacement in positions(c["args"]):
            args=list(c["args"]); args[i]=replacement
            for vn,ve in VALUES.items():
                prog=(c.get("setup") or "")+f"\nnf is {ve}\nprint of ({call(c['name'],args)})\n"
                rows.append((c["name"],i,kind,vn,"direct",*[run.run(prog,m) for _,m in MODES]))
    write_tsv(ns.out,["population: every numeric position in tests/strict_shape_cases.json"],rows)
    return summary(rows,run)

# Candidate store paths are deliberately executable data: only candidates whose bit snapshot
# proves the requested payload are reported as producers.
PRODUCER_CANDIDATES = {
 "f64_from_bits_store": "buf_set_bits of [{buffer}, {index}, f64_bits of nf]",
 "buf_set": "buf_set of [{buffer}, {index}, nf]",
 "copy_into": "copy_into of [{buffer}, {index}, [nf]]",
 "buf_scale_range": "buf_set_bits of [{buffer}, {index}, 9214364837600034816]\nbuf_scale_range of [{buffer}, {index}, 1, 2]",
}
BITS={"inf":"9218868437227405312","ninf":"-4503599627370496","nan":"9221120237041090560"}

def buffer_forms(ns, root, run):
    api=subprocess.run([run.binary,"--api","--json"],capture_output=True,text=True,check=True).stdout.lower()
    cs=cases(root); rows=[("builtin","arg","kind","value","producer","unset","s0","s1")]
    controls, clean_controls = {}, set()
    # Cases determine callable shapes; API JSON must independently mention buffer for the name.
    for c in cs:
        n=c["name"]
        if n in EXCLUDED or c.get("requirements") or n.lower() not in api: continue
        setup=c.get("setup") or ""
        bufvars=set(re.findall(r"\b([a-zA-Z_][a-zA-Z_0-9]*) is (?:shape_set of )?(?:buffer of|buf_from_list of)",setup))
        for i,a in enumerate(c["args"]):
            var=a.strip()
            if var not in bufvars: continue
            control_prog=setup+f"\nprint of ({call(n,c['args'])})\n"
            control=tuple(run.run(control_prog,m) for _,m in MODES)
            control_error=any(not x.startswith("val(") for x in control)
            controls[(n,i)]=not control_error
            if not control_error: clean_controls.add((n,i))
            recorded=tuple("CONTROL_ERR("+x+")" if control_error else x for x in control)
            rows.append((n,i,"buffer","control","control",*recorded))
            if control_error: continue
            for vn,ve in VALUES.items():
                for pn,body in PRODUCER_CANDIDATES.items():
                    step=body.format(buffer=var,index=0)
                    probe=f"{setup}\nnf is {ve}\n{step}\nprint of ((buf_get_bits of [{var}, 0]) == {BITS[vn]})\n"
                    if not run.run(probe).startswith("val(true"):
                        rows.append((n,i,"buffer",vn,pn,"NO_PRODUCER","NO_PRODUCER","NO_PRODUCER"))
                        continue
                    prog=f"{setup}\nnf is {ve}\n{step}\nprint of ({call(n,c['args'])})\n"
                    rows.append((n,i,"buffer",vn,pn,*[run.run(prog,m) for _,m in MODES]))
    producers=sorted(PRODUCER_CANDIDATES)
    write_tsv(ns.out,["population: buffer-taking names are the intersection of --api --json and buffer variables in tests/strict_shape_cases.json", "producers: "+",".join(producers)],rows)
    probed_builtins={n for n,_ in controls}; clean_builtins={n for n,_ in clean_controls}
    bad=sorted(probed_builtins-clean_builtins)
    extra=(f"producers={','.join(producers)} clean_controls={len(clean_controls)}/{len(controls)} "
           f"clean_builtins={len(clean_builtins)}/{len(probed_builtins)} control_errors={','.join(bad) or '-'}")
    rc=summary(rows,run,extra)
    if probed_builtins and len(clean_builtins)*5 < len(probed_builtins)*4: rc=1
    return rc

def diff(a,b):
    def load(p):
        lines=[x.rstrip("\n").split("\t") for x in open(p) if not x.startswith("#")]
        return {tuple(r[:5]):tuple(r[-3:]) for r in lines[1:]}
    x,y=load(a),load(b); keys=sorted(set(x)|set(y)); changed=[k for k in keys if x.get(k)!=y.get(k)]
    print("builtin\targ\tkind\tvalue\tproducer\tbase\thead")
    for k in changed: print("\t".join(k+("/".join(x.get(k,("MISSING",))),"/".join(y.get(k,("MISSING",))))))
    print(f"differ={len(changed)}"); return 0

def main():
    p=argparse.ArgumentParser(); p.add_argument("--diff",nargs=2,metavar=("BASE","HEAD"))
    sub=p.add_subparsers(dest="command")
    for name in ("one-number","list-forms","buffer-forms"):
        q=sub.add_parser(name); q.add_argument("binary"); q.add_argument("--out"); q.add_argument("--timeout",type=float,default=10); q.add_argument("--allow-timeout",action="store_true")
    ns=p.parse_args()
    if ns.diff:return diff(*ns.diff)
    if not ns.command:p.error("a subcommand or --diff is required")
    root=Path(__file__).resolve().parents[1]; run=Runner(ns.binary,ns.timeout,ns.allow_timeout)
    return {"one-number":one_number,"list-forms":list_forms,"buffer-forms":buffer_forms}[ns.command](ns,root,run)
if __name__=="__main__": raise SystemExit(main())
