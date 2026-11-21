#!/usr/bin/env python3
"""#2474: reads and captures never turn an outward assignment local."""
import json, os, re, subprocess, sys, tempfile

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
# A function that also declares the name `local`: the write lands where it lands in the same function
# without the read or the inner function (2 and 2, 5 and 2, 1 and 9).  And a function that holds a
# comprehension variable or a catch name of the same name: those have the scope of their expression and
# of their handler (docs/SPEC.md), so a write outside that scope lands on the module's name (2), before
# the binder or after it, while a write inside the handler stays the handler's (1).
cb1 is 9
define cbf1(c) as:
    if c:
        local cb1 is 1
    cb1 is 2
    t is when is cb1
    return cb1
print of ["local in an untaken branch, with a read", cbf1 of 0, cb1]
cb2 is 9
define cbf2(c) as:
    if c:
        local cb2 is 1
    cb2 is 2
    define cbinner2(q) as:
        return cb2
    return cbinner2 of null
print of ["local in an untaken branch, with an inner function", cbf2 of 0, cb2]
cb3 is 9
define cbf3(c) as:
    cb3 is 2
    local cb3 is 5
    t is when is cb3
    return cb3
print of ["local after the write, with a read", cbf3 of 0, cb3]
cb4 is 9
define cbf4(c) as:
    local cb4 is 1
    cb4 is 2
    return prev of cb4
print of ["local before the write, with a read", cbf4 of 1, cb4]
cb5 is 1
define cbf5(c) as:
    ignored is [cb5 for cb5 in [7, 8]]
    cb5 is 2
    t is when is cb5
    return cb5
print of ["a write after a comprehension of the name, with a read", cbf5 of 0, cb5]
cb6 is 1
define cbf6(c) as:
    try:
        v is 1 // 0
    catch cb6:
        v is 0
    cb6 is 2
    t is when is cb6
    return cb6
print of ["a write after a catch of the name, with a read", cbf6 of 0, cb6]
cb7 is 1
define cbf7(c) as:
    t is 0
    try:
        throw of "boom"
    catch cb7:
        cb7 is 5
        t is cb7
    return [t, cb7]
print of ["a write inside the handler stays the handler's", cbf7 of 0, cb7]
cb8 is 1
define cbf8(c) as:
    fs is [(() => cb8) for cb8 in [7, 8]]
    cb8 is 2
    return [(fs[0]) of null, (fs[1]) of null, cb8]
print of ["closures made in a comprehension keep its variable", cbf8 of 0, cb8]
cb9 is 1
define cbf9(c) as:
    cb9 is 3
    r is [cb9 + v for v in [1]]
    try:
        throw of "x"
    catch cb9:
        r2 is 0
    return [cb9, r]
print of ["a write before a comprehension and a catch of the name", cbf9 of 0, cb9]
'''
EXTRA_WANTS = ['["after +=", 11]', '["after destructure", 7]',
 '["after h twice (read c then write)", 3]', '["after f with lambda capturing x", 2]',
 '["after h with lambda reading when", 2]', '["after comp read", 2]',
 '["after for-accumulate with read", 6]', '["field write crosses", {"k": 2}]',
 '["rebind with read", {"k": 3}]', '["total after 3 add (captured by lambda)", 15]',
 '["local in an untaken branch, with a read", 2, 2]',
 '["local in an untaken branch, with an inner function", 2, 2]',
 '["local after the write, with a read", 5, 2]', '["local before the write, with a read", 1, 9]',
 '["a write after a comprehension of the name, with a read", 2, 2]',
 '["a write after a catch of the name, with a read", 2, 2]',
 '["a write inside the handler stays the handler\'s", [5, 1], 1]',
 '["closures made in a comprehension keep its variable", [8, 8, 2], 2]',
 '["a write before a comprehension and a catch of the name", [3, [4]], 3]']
# The 17 reads of a name's history, the forms the fault was in.  In the entry-JIT setting the function
# of every such cell that writes a STRING BEFORE its read (the read after the write, or in a nested
# block) must be one the JIT compiled (EIGS_JIT_DEBUG names each function it compiles): 68 cells.
# Not asked for, because the write does not run in compiled code there: a cell whose read comes first
# (the JIT compiles a function up to the first operation it does not know, and stops at the read), and a
# cell that writes an int or a list (an integer literal stops the scanner, INT_CONST: integer code is
# interpreted until the integer fast paths exist).
HISTORY = ("what", "who", "when", "where", "why", "how", "prev", "what_at", "who_at", "when_at",
           "where_at", "why_at", "how_at", "prev_at", "what_when", "who_when", "prev_when")

def add(lines, text): lines.extend(text.splitlines())
def expr(template, name, line): return template.replace("x", name).replace("{L}", str(line))

def build():
    # One nondeterministic value: a replay prints the recorded one only if it reads the tape.
    lines, cells = ['print of ["NONDET", random of null]'], []
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
        cells.append((tag, init, new, read == "LOCAL", x, ox, rk, f, vk, pos))
    return "\n".join(lines) + "\n", cells

def run(src, env, stats=None):
    p = subprocess.run([EIGS, src], text=True, capture_output=True,
                       env={**os.environ, **env}, timeout=180)
    if p.returncode: raise RuntimeError(p.stderr or f"exit {p.returncode}")
    if stats is not None: stats.append(p.stderr)
    return p.stdout

def jit_problems(stderr, cells):
    """The entry-JIT run must have run the write of the cells it can compile in compiled code, not
    interpreted them without a word: no function turned away for a full code cache (EIGS_JIT_STATS's
    line), and the function of every string-writing history cell whose write comes before its read
    named as compiled (EIGS_JIT_DEBUG's lines)."""
    m = re.search(r"\[jit\] scanned=(\d+) compiled=(\d+) cache_used=\d+ cache_full_rejects=(\d+)", stderr)
    if not m: return ["no [jit] statistics line"], "no statistics"
    scanned, compiled, rejects = map(int, m.groups())
    named = set(re.findall(r"^\[jit\] compiled (\S+):", stderr, re.M))
    want = [c[7] for c in cells if c[6] in HISTORY and c[8] == "str" and c[9] != "before"]
    missing = [f for f in want if f not in named]
    bad = []
    if rejects: bad.append(f"{rejects} function(s) not compiled: the code cache was full")
    if missing: bad.append(f"{len(missing)} of the {len(want)} write-first string cells of the history reads were not compiled: {' '.join(missing[:8])}")
    return bad, f"{len(want) - len(missing)} of {len(want)} write-first string cells of the history reads compiled; compiled={compiled} of scanned={scanned}, cache_full_rejects={rejects}"

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
    for tag, init, new, local, x, ox, _rk, _f, _vk, _pos in cells:
        want = json.loads(init if local else new)
        if outs.get(tag) != [want]: failures.append(f"{tag}: OUT {outs.get(tag)!r} != {want!r}")
        if norm(reads.get(tag), x) != norm(oracle.get(tag), ox):
            failures.append(f"{tag}: READ {reads.get(tag)!r} != {oracle.get(tag)!r}")
    return failures

def main():
    source, cells = build()
    tiers = [("interp", {"EIGS_JIT_OFF": "1"}), ("default", {}),
             ("osr", {"EIGS_JIT_OSR_THRESHOLD": "1"}),
             # The default code cache (1 MB) fills before half of the 534 cells are compiled, and the
             # rest would run interpreted without a word; 2048 pages hold them all.
             ("entry", {"EIGS_JIT_ENTRY_THRESHOLD": "1", "EIGS_JIT_ITER_THRESHOLD": "1",
                        "EIGS_JIT_CACHE_PAGES": "2048", "EIGS_JIT_STATS": "1", "EIGS_JIT_DEBUG": "1"})]
    assert all(h in READS for h in HISTORY)
    assert sum(1 for c in cells if c[6] in HISTORY and c[8] == "str" and c[9] != "before") == len(HISTORY) * (len(POSITIONS) - 1) * len(CALLS)
    failed = 0
    with tempfile.TemporaryDirectory() as td:
        src = os.path.join(td, "matrix.eigs")
        open(src, "w", encoding="utf-8").write(source)
        for name, env in tiers:
            stats = []
            bad = check(run(src, env, stats), cells); note = ""
            if name == "entry":
                more, said = jit_problems(stats[0], cells); bad += more; note = f" ({said})"
            failed += len(bad)
            print(("PASS" if not bad else "FAIL") + f": assignment matrix {name}{note}")
            for msg in bad[:20]: print("  " + msg)
            open(src, "w", encoding="utf-8").write(EXTRA)
            extra = run(src, env).splitlines()
            missing = [line for line in EXTRA_WANTS if line not in extra]
            failed += len(missing)
            print(("PASS" if not missing else "FAIL") + f": assignment regressions {name}")
            for line in missing[:20]: print("  missing: " + line)
            open(src, "w", encoding="utf-8").write(source)
        tape = os.path.join(td, "matrix.trace")
        recorded = run(src, {"EIGS_TRACE": tape})
        for name, env in (("record", {"EIGS_TRACE": tape}), ("replay", {"EIGS_REPLAY": tape})):
            out = recorded if name == "record" else run(src, env)
            bad = check(out, cells)
            if name == "replay" and out != recorded: bad.append("replay differs from recording")
            failed += len(bad); print(("PASS" if not bad else "FAIL") + f": assignment matrix {name}")
    # every cell in the four settings and in the recording and its replay; every row of the second
    # program in the four settings
    print(f"examined={len(cells) * (len(tiers) + 2) + len(EXTRA_WANTS) * len(tiers)} failed={failed}")
    return bool(failed)
if __name__ == "__main__": sys.exit(main())
