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

def classify(stdout, stderr, rc):
    output = stderr if rc and stderr else stdout
    lines = output.strip().splitlines()
    first = next((line for line in lines if line.startswith("Error")), lines[0] if lines else "")
    text = re.sub(r"^Error [^ ]+:\d+: ", "", first)
    for name, needles in CLASS_PATTERNS:
        if any(x in text for x in needles): return name
    if first.startswith("Error") or rc: return "ERR(" + text[:38] + ")"
    snapshots = "|".join(line for line in lines[1:] if line.startswith("CENSUS"))
    return "val(" + first + ")" + ("|" + snapshots if snapshots else "")

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
        return classify(r.stdout, r.stderr, r.returncode)

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

def snapshot_call(setup, expression, bufvars):
    snapshots = "".join(f'__census_snapshot of ["{v}", {v}]\n' for v in sorted(bufvars))
    before=""
    changes=""
    for v in sorted(bufvars):
        before += f'__census_before_{v} is [buf_get_bits of [{v}, __i] for __i in range of (len of {v})]\n'
        changes += f'''__census_changed_{v} is []
for __i in range of (len of {v}):
    if (buf_get_bits of [{v}, __i]) != __census_before_{v}[__i]:
        append of [__census_changed_{v}, __i]
print of ("CENSUS_CHANGE:{v}:" + (str of __census_changed_{v}))
'''
    return f'''{setup}
define __census_snapshot(__name, __buf) as:
    __bits is []
    __nonfinite is 0
    for __i in range of (len of __buf):
        __bit is f64_bits of (f64_from_bits of (buf_get_bits of [__buf, __i]))
        append of [__bits, __bit]
        if ((__bit >> 52) & 2047) == 2047:
            __nonfinite is __nonfinite + 1
    print of ("CENSUS:" + __name + ":" + (sha256 of (str of __bits)) + ":" + (str of __nonfinite))
{before}
__answer is {expression}
print of __answer
if (type of __answer) == "buffer":
    __census_snapshot of ["return", __answer]
{snapshots}
{changes}'''

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
    print("summary " + " ".join(fields) + " excluded=" + ",".join(EXCLUDED) + (" " + extra if extra else ""), file=sys.stderr)
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
 "tensor_add": "__census_big is buffer of 1\nbuf_set of [__census_big, 0, 1e308]\n__census_sum is add of [__census_big, __census_big]\nbuf_set_bits of [{buffer}, {index}, buf_get_bits of [__census_sum, 0]]",
}
BITS={"inf":"9218868437227405312","ninf":"-4503599627370496","nan":"9221120237041090560"}

def buffer_length(run, setup, var):
    answer=run.run(f"{setup}\nprint of (len of {var})\n")
    m=re.match(r"val\((\d+)\)",answer)
    return int(m.group(1)) if m else 0

def candidate_buffer(run, c, i):
    """Execute the case shape with argument i converted to a numeric buffer."""
    args=list(c["args"]); source=args[i]
    args[i]="__census_candidate"
    program=(c.get("setup") or "")+f"\n__census_candidate is buf_from_list of ({source})\nprint of ({call(c['name'],args)})\n"
    return all(run.run(program,mode).startswith("val(") for _,mode in MODES)

def read_cells(name, arg, args, length):
    """Indices explicitly selected by buffer calls; other consumers read the whole value."""
    def integer(i):
        try: return int(args[i].strip())
        except (ValueError, IndexError): return None
    if name in ("buf_get","buf_get_bits","buf_set","buf_set_bits"):
        x=integer(1); return {x} if arg == 0 and x is not None else set()
    if name in ("buf_fill","buf_scale_range","buf_deinterleave") and arg == 0:
        start,count=integer(1),integer(2)
        return set(range(start,start+count)) if start is not None and count is not None else set()
    if name == "buf_copy":
        start=integer(1 if arg == 0 else 3); count=integer(4)
        return set(range(start,start+count)) if arg in (0,2) and start is not None and count is not None else set()
    if name == "buf_len": return set()
    return set(range(length))

def buffer_forms(ns, root, run):
    api=json.loads(subprocess.run([run.binary,"--api","--json"],capture_output=True,text=True,check=True).stdout)
    entries=api if isinstance(api,list) else api.get("builtins",[])
    api_names={x if isinstance(x,str) else x["name"] for x in entries}
    cs=cases(root); rows=[("builtin","arg","cell","touch","value","producer","unset","s0","s1")]
    controls, clean_controls, used_producers = {}, set(), set()
    for c in cs:
        n=c["name"]
        if n in EXCLUDED or n not in api_names: continue
        base_setup=c.get("setup") or ""
        bufvars=set(re.findall(r"\b([a-zA-Z_][a-zA-Z_0-9]*) is (?:shape_set of )?(?:buffer of|buf_from_list of)",base_setup))
        for i,a in enumerate(c["args"]):
            setup=base_setup
            var=a.strip(); is_existing=var in bufvars
            listish=is_existing or var.startswith("[") or bool(re.search(rf"\b{re.escape(var)} is \[",setup))
            if not listish: continue
            # Population membership is an executed conversion, not API metadata or a hand list.
            if c.get("requirements"):
                requirement=",".join(c["requirements"])
                rows.append((n,i,"-","SKIPPED("+requirement+")","control","control",*("SKIPPED("+requirement+")",)*3))
                continue
            if not is_existing and not candidate_buffer(run,c,i): continue
            if not is_existing:
                var="__census_buffer"
                setup += f"\n{var} is buf_from_list of ({a})"
                case_args=list(c["args"]); case_args[i]=var
            else: case_args=c["args"]
            length=buffer_length(run,setup,var)
            touched=read_cells(n,i,case_args,length)
            control_prog=snapshot_call(setup, call(n,c["args"]), bufvars)
            if not is_existing:
                control_prog=snapshot_call(setup,call(n,case_args),{var})
            control=tuple(run.run(control_prog,m) for _,m in MODES)
            control_error=any(not x.startswith("val(") for x in control)
            controls[(n,i)]=not control_error
            if not control_error: clean_controls.add((n,i))
            recorded=tuple("CONTROL_ERR("+x+")" if control_error else x for x in control)
            rows.append((n,i,"-","read="+",".join(map(str,sorted(touched))),"control","control",*recorded))
            if control_error: continue
            for vn,ve in VALUES.items():
                for pn,body in PRODUCER_CANDIDATES.items():
                    cells=[]
                    for cell in range(length):
                        step=body.format(buffer=var,index=cell)
                        prog=snapshot_call(f"{setup}\nnf is {ve}\n{step}",call(n,case_args),{var})
                        answers=[]
                        for _,m in MODES:
                            probe=f"{setup}\nnf is {ve}\n{step}\nprint of ((buf_get_bits of [{var}, {cell}]) == {BITS[vn]})\n"
                            if not run.run(probe,m).startswith("val(true"):
                                answers.append("NO_PRODUCER")
                            elif cell not in touched:
                                answers.append("UNTOUCHED")
                            else:
                                answers.append(run.run(prog,m)); used_producers.add(pn)
                        rows.append((n,i,cell,"read" if cell in touched else "none",vn,pn,*answers))
    producers=sorted(used_producers)
    write_tsv(ns.out,["population: every core builtin case in tests/strict_shape_cases.json whose list-literal or list-variable argument answers when replaced at runtime by a buffer of the same numbers; requirement-gated cases are SKIPPED", "producers: "+",".join(producers)],rows)
    probed_builtins={n for n,_ in controls}; clean_builtins={n for n,_ in clean_controls}
    bad=sorted(probed_builtins-clean_builtins)
    extra=(f"producers={','.join(producers)} clean_controls={len(clean_controls)}/{len(controls)} "
           f"clean_builtins={len(clean_builtins)}/{len(probed_builtins)} control_errors={','.join(bad) or '-'}")
    rc=summary(rows,run,extra)
    if probed_builtins and len(clean_builtins)*5 < len(probed_builtins)*4: rc=1
    return rc

def diff(a,b):
    def load(p):
        with open(p) as f:
            lines=[x.rstrip("\n").split("\t") for x in f if not x.startswith("#")]
        return {tuple(r[:6]):tuple(r[-3:]) for r in lines[1:]}
    x,y=load(a),load(b); keys=sorted(set(x)|set(y)); changed=[k for k in keys if x.get(k)!=y.get(k)]
    print("builtin\targ\tcell\ttouch\tvalue\tproducer\tbase\thead")
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
