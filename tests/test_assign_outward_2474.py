#!/usr/bin/env python3
"""#2474: reads and captures never turn an outward assignment local."""
import json, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EIGS = os.environ.get("EIGS", os.path.join(ROOT, "src", "eigenscript"))
READS = {
    "what": "what is x", "who": "who is x", "when": "when is x", "where": "where is x",
    "why": "why is x", "how": "how is x", "prev": "prev of x",
    "what_at": "what is x at {L}", "who_at": "who is x at {L}", "when_at": "when is x at {L}",
    "where_at": "where is x at {L}", "why_at": "why is x at {L}", "how_at": "how is x at {L}",
    "prev_at": "prev of x at {L}", "what_when": "what is x when 1",
    "who_when": "who is x when 1", "prev_when": "prev of x when 1",
    "converged": "converged of x", "stable": "stable of x", "improving": "improving of x",
    "diverging": "diverging of x", "oscillating": "oscillating of x", "equilibrium": "equilibrium of x",
    "report": "report of x", "report_value": "report_value of x", "observe": "observe of x",
    "trajectory": "trajectory of x", "classify_traj": "classify of (trajectory of x)",
    "state_at": "state_at of {L}", "CONTROL_none": None, "CONTROL_local": "LOCAL",
}
POSITIONS = ["after", "before", "nested"]
CALLS = ["once", "loop3"]
VALUES = {"num": ("1", "2"), "str": ('"a"', '"b"'), "list": ("[1]", "[2]")}
EXTRA = r'''x is 1
define f(ignored) as:
    x += 10
    print of ["f when", when is x]
f of null
print of ["after +=", x]
a is 1
define g(ignored) as:
    [a, bb] is [7, 8]
    print of ["g when", when is a]
g of null
print of ["after destructure", a]
c is 1
define h(ignored) as:
    c is c + 1
    print of [what is c]
h of null
h of null
print of ["after h twice (read c then write)", c]
x is 1
define fl(ignored) as:
    x is 2
    gl is (v) => v + x
    print of ["lambda sees", gl of 0]
fl of null
print of ["after f with lambda capturing x", x]
y is 1
define hl(ignored) as:
    y is 2
    kl is () => (when is y)
    print of ["lambda when", kl of null]
hl of null
print of ["after h with lambda reading when", y]
x is 1
define fc(ignored) as:
    x is 2
    print of [[when is x for v in [1]]]
fc of null
print of ["after comp read", x]
s is 0
define gf(ignored) as:
    for v in [1, 2, 3]:
        s is s + v
    print of ["g when s", when is s]
gf of null
print of ["after for-accumulate with read", s]
d is {"k": 1}
define fd(ignored) as:
    d.k is 2
    print of [when is d]
fd of null
print of ["field write crosses", d]
d2 is {"k": 1}
define gd(ignored) as:
    d2 is {"k": 3}
    print of [when is d2]
gd of null
print of ["rebind with read", d2]
total is 0
define add(v) as:
    total is total + v
    helper is (u) => u + total
k is 0
loop while k < 3:
    add of 5
    k is k + 1
print of ["total after 3 add (captured by lambda)", total]
'''
EXTRA_WANTS = ['["after +=", 11]', '["after destructure", 7]',
 '["after h twice (read c then write)", 3]', '["after f with lambda capturing x", 2]',
 '["after h with lambda reading when", 2]', '["after comp read", 2]',
 '["after for-accumulate with read", 6]', '["field write crosses", {"k": 2}]',
 '["rebind with read", {"k": 3}]', '["total after 3 add (captured by lambda)", 15]']

def add(lines, text): lines.extend(text.splitlines())
def expr(template, name, line): return template.replace("x", name).replace("{L}", str(line))

def build():
    lines, cells = [], []
    specs = [(r, p, c, v) for r in READS if not r.startswith("CONTROL_")
             for p in POSITIONS for c in CALLS for v in VALUES]
    specs += [(r, "after", c, v) for r in ("CONTROL_none", "CONTROL_local")
              for c in CALLS for v in VALUES]
    for n, (rk, pos, call, vk) in enumerate(specs):
        tag, x, f = str(n), "x" + str(n), "f" + str(n)
        init, new = VALUES[vk]; read = READS[rk]
        lines.append(f"{x} is {init}")
        lines.append(f"define {f}(ignored) as:")
        assign_line = len(lines) + (2 if pos == "before" else 1)
        assignment = f"    {'local ' if read == 'LOCAL' else ''}{x} is {new}"
        rd = None if read in (None, "LOCAL") else expr(read, x, assign_line)
        read_line = f'    print of ["P", "{tag}", {rd}]' if rd else f'    print of ["P", "{tag}", "none"]'
        if pos == "before": lines += [read_line, assignment]
        elif pos == "nested": lines += [assignment, "    if true:", "    " + read_line]
        else: lines += [assignment, read_line]
        if call == "once": lines.append(f"{f} of null")
        else:
            lines += [f"k{n} is 0", f"loop while k{n} < 3:", f"    {f} of null", f"    k{n} is k{n} + 1"]
        lines.append(f'print of ["OUT", "{tag}", {x}]')
        # The equivalent program has a distinct binding but the same initial
        # history; its read is at module level beside the plain-writing call.
        ox, of = "ox" + str(n), "of" + str(n)
        lines += [f"{ox} is {init}", f"define {of}(ignored) as:", f"    {ox} is {new}", f"    ok{n} is 0"]
        if pos == "nested": lines += ["    if true:", f"        ok{n} is 1"]
        oracle_assign_line = len(lines) - (3 if pos == "nested" else 1)
        ore = None if read in (None, "LOCAL") else expr(read, ox, oracle_assign_line)
        ordline = f'print of ["O", "{tag}", {ore}]' if ore else f'print of ["O", "{tag}", "none"]'
        one = [ordline, f"{of} of null"] if pos == "before" else [f"{of} of null", ordline]
        if call == "once": lines += one
        else:
            lines += [f"okloop{n} is 0", f"loop while okloop{n} < 3:"]
            lines += ["    " + s for s in one] + [f"    okloop{n} is okloop{n} + 1"]
        cells.append((tag, init, new, read == "LOCAL", x, ox))
    return "\n".join(lines) + "\n", cells

def run(src, env):
    p = subprocess.run([EIGS, src], text=True, capture_output=True,
                       env={**os.environ, **env}, timeout=180)
    if p.returncode: raise RuntimeError(p.stderr or f"exit {p.returncode}")
    return p.stdout

def check(out, cells):
    reads, oracle, outs = {}, {}, {}
    for line in out.splitlines():
        try: row = json.loads(line)
        except json.JSONDecodeError: continue
        if isinstance(row, list) and len(row) == 3 and row[0] in ("P", "O", "OUT"):
            ({"P": reads, "O": oracle, "OUT": outs}[row[0]]).setdefault(row[1], []).append(row[2])
    failures = []
    def norm(value, name):
        if isinstance(value, str): return value.replace(name, "$binding")
        if isinstance(value, list): return [norm(v, name) for v in value]
        if isinstance(value, dict): return {k: norm(v, name) for k, v in value.items()}
        return value
    for tag, init, new, local, x, ox in cells:
        want = json.loads(init if local else new)
        if outs.get(tag) != [want]: failures.append(f"{tag}: OUT {outs.get(tag)!r} != {want!r}")
        if norm(reads.get(tag), x) != norm(oracle.get(tag), ox):
            failures.append(f"{tag}: READ {reads.get(tag)!r} != {oracle.get(tag)!r}")
    return failures

def main():
    source, cells = build()
    tiers = [("interp", {"EIGS_JIT_OFF": "1"}), ("default", {}),
             ("osr", {"EIGS_JIT_OSR_THRESHOLD": "1"}),
             ("entry", {"EIGS_JIT_ENTRY_THRESHOLD": "1", "EIGS_JIT_ITER_THRESHOLD": "1"})]
    failed = 0
    with tempfile.TemporaryDirectory() as td:
        src = os.path.join(td, "matrix.eigs")
        open(src, "w", encoding="utf-8").write(source)
        for name, env in tiers:
            bad = check(run(src, env), cells); failed += len(bad)
            print(("PASS" if not bad else "FAIL") + f": assignment matrix {name}")
            for msg in bad[:20]: print("  " + msg)
            open(src, "w", encoding="utf-8").write(EXTRA)
            extra = run(src, env).splitlines()
            missing = [line for line in EXTRA_WANTS if line not in extra]
            failed += len(missing)
            print(("PASS" if not missing else "FAIL") + f": assignment regressions {name}")
            open(src, "w", encoding="utf-8").write(source)
        tape = os.path.join(td, "matrix.trace")
        recorded = run(src, {"EIGS_TRACE": tape})
        for name, env in (("record", {"EIGS_TRACE": tape}), ("replay", {"EIGS_REPLAY": tape})):
            out = recorded if name == "record" else run(src, env)
            bad = check(out, cells)
            if name == "replay" and out != recorded: bad.append("replay differs from recording")
            failed += len(bad); print(("PASS" if not bad else "FAIL") + f": assignment matrix {name}")
    print(f"examined={len(cells) * (len(tiers) + 2)} failed={failed}")
    return bool(failed)
if __name__ == "__main__": sys.exit(main())
