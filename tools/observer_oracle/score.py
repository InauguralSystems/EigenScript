#!/usr/bin/env python3
"""Score EigenScript's observer against a ground-truth corpus (#1746, #1758).

usage: score.py BINARY [--corpus PATH] [--numbers ieee|clamp]
                       [--floor FILE] [--write-floor FILE [--note TEXT]]

Labels come from labels.json, which must equal derive.py's derivation from the
certified corpus (the label gate). Each predicate is scored against ONE
question, its scored definition in the corpus (converged, stable, improving:
CONVENTION; oscillating, diverging, equilibrium: MATH); MATH "has a limit" is
a reported column, never scored. Each row is generated in Python and run on
BINARY in four ARMS:
  interp/straight  straight-line code, EIGS_JIT_OFF=1, reading every checkpoint
  interp/loop      a loop form per checkpoint c, EIGS_JIT_OFF=1
  jit/loop         the same after 50 zero-iteration calls, so the default JIT
                   has compiled run_row before the measured call
  osr/loop         the same under EIGS_JIT_OSR_THRESHOLD=1 (OSR thunks)
The loop form assigns x_0..x_c in `loop while i < m` (x from a list, or
x * a + b computed in the runtime) and then reads c. Its compile stops at the
read (PREDICATE_NAME), so predicate reads always run interpreted; the
assignments are what the tiers exercise. Each jit/osr run measures its NATIVE
ASSIGNMENT SHARE from EIGS_JIT_HOT, EIGS_JIT_DEBUG and EIGS_DUMP_BC: jit,
(m - interpreted back-edges) / m when a function thunk spans the loop (exact:
an interpreted iteration always takes one interpreted back-edge); osr,
(OSR entries - 1) / m when an OSR thunk spans the loop body (an upper bound: a
runtime bail inside an OSR thunk is counted by no runtime counter). A tier
whose share is below 50% is VACUOUS (exit 2).

Every value the runtime holds is compared exactly with the generator's
(bit-exact floats, ints exactly, inf/NaN per --numbers, which is probed with
`print of (1e308 * 10)`), and every read must fall after the assignment of
x_c and before x_{c+1} (`when is x` counts the binding's assignments). A row
with a `capability` runs only on a binary that has it (ieee: `print of
(0.0/0.0)` prints nan; int64: `print of 9223372036854775807` round-trips);
skips are counted and printed. The reference model (reference.py) is scored
on the distance signal and on the runtime's entropy signal (#1667); it
implements the definitions at the observer's own window and tolerances, so it
is correlated with the runtime on window-limited rows, not independent.

Exit 1: a FINDING (one reading that differs between arms), a wrong verdict on
a capability row, or (--floor) a floor verdict now wrong that waivers.json,
beside the floor, does not name with a reason. --floor re-runs the binary the
floor records (sha256 verified) and refuses a floor whose verdict list is not
that measurement. --write-floor records this run's right verdicts on rows
without a capability. Exit 2 on any harness error (a program that errors, a
missing, duplicate or misordered output line, a value that differs from the
generator, a vacuous tier, a stale certificate, labels that differ from the
derivation, a refused floor or waiver, an internal exception).
"""
import hashlib
import json
import math
import os
import re
import struct
import subprocess
import sys
import tempfile

import derive
import reference
from derive import PREDS
from gen import HarnessError, INT64_MIN, IN_PROGRAM, generate, program

ROW_TIMEOUT = 120
CLAMP = 1e308          # the default build saturates here (EIGS_NUM_MAX)
HERE = os.path.dirname(os.path.abspath(__file__))
TIERS = {"interp": {"EIGS_JIT_OFF": "1"}, "jit": {}, "osr": {"EIGS_JIT_OSR_THRESHOLD": "1"}}
ARMS = (("interp", "straight"), ("interp", "loop"), ("jit", "loop"), ("osr", "loop"))
WARMUP = {"interp": 0, "jit": 50, "osr": 0}       # src/jit.c: a function compiles at 50 calls
DIAG = {"EIGS_JIT_HOT": "1", "EIGS_JIT_DEBUG": "1", "EIGS_DUMP_BC": "1"}
NATIVE_FLOOR = 0.5
PROBES = {"numbers": "print of (1e308 * 10)", "ieee": "print of (0.0/0.0)",
          "int64": "print of 9223372036854775807"}
HAS = {"ieee": "nan", "int64": "9223372036854775807"}
FLOOR_FORMAT = "per-verdict/1"
HOT_BLOCK = re.compile(r"=== Hot chunks.*?\n  bytes native: [^\n]*", re.S)
DIAG_LINE = re.compile(r"^(\[jit\] |=== .* ===$|\d{4,} \[L\d+\] )")


def read_expr(pred):
    """The one place a predicate read is spelled (per-variable form)."""
    return f"{pred} of x"


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def load_labels(corpus, certs, path):
    """The label gate: labels.json must equal derive(corpus), whose own
    postconditions hold (one scored entry per predicate, the lattice)."""
    try:
        with open(path) as f:
            committed = json.load(f)
    except (OSError, ValueError) as e:
        raise HarnessError(f"cannot load labels {path}: {e}")
    derived = derive.derive(corpus, certs)
    diff = sorted(k for k in set(committed) | set(derived) if committed.get(k) != derived.get(k))
    if diff:
        raise HarnessError(f"labels.json differs from derive.py at {len(diff)} checkpoint(s),"
                           f" first {diff[0]}; regenerate with derive.py --write")
    return committed


# --- programs ---------------------------------------------------------------

def literal(v):
    """Round-trip spelling: an int row's integer literal (INT64_MIN as the
    Lua idiom, since a lone 9223372036854775808 is a float under N1), or a
    float literal with float(literal(v)) == v in every bit."""
    if isinstance(v, int):
        return "-9223372036854775807 - 1" if v == INT64_MIN else str(v)
    if not math.isfinite(v):
        raise HarnessError(f"non-finite literal {v!r}: inf and NaN must be computed in the program")
    return repr(v)


def steps(row, xs, upto):
    """x_0..x_upto as the runtime assigns them: a literal, or x * a + b."""
    if row["gen"]["kind"] in IN_PROGRAM:
        return program(row["gen"], upto)
    return [("set", v) for v in xs[:upto + 1]]


def ck_line(at, ys):
    reads = " ".join("{" + read_expr(p) + "}" for p in PREDS)
    whens = " {when is x}" + (" {when is y}" if ys is not None else "")
    return f'print of f"CK {at} {reads}{whens}"'


def emit_straight(row, xs, ys):
    """Every assignment is followed by a V (and Y) line carrying the runtime's
    value, and every checkpoint line by `when is x` (and y)."""
    out, cks = [], set(row["checkpoints"])
    for i, s in enumerate(steps(row, xs, row["n"])):
        out.append(f"x is {literal(s[1])}" if s[0] == "set"
                   else f"x is x * {literal(s[1])} + {literal(s[2])}")
        out.append(f'print of f"V {i} {{x}}"')
        if ys is not None:
            out += [f"y is {literal(ys[i])}", f'print of f"Y {i} {{y}}"']
        if i in cks:
            out.append(ck_line(i, ys))
    return "\n".join(out + [f'print of "ROW_DONE {row["id"]}"']) + "\n"


def table(name, vals):
    """`name is [...]`, chunked: a list literal holds at most 1024 elements."""
    out = []
    for c in range(0, max(len(vals), 1), 1000):
        lit = "[" + ", ".join(literal(v) for v in vals[c:c + 1000]) + "]"
        out += [f"{name} is {lit}"] if c == 0 else [f"for v in {lit}:", f"    append of [{name}, v]"]
    return out


def emit_loop(row, xs, ys, c, warm):
    """run_row(m) makes the first m assignments in a `loop while` the
    function JIT compiles (B[i], or x * A[i] + B[i] in the runtime), records
    them in OUT, then reads checkpoint c. `warm` calls with m = 0 come first:
    they compile run_row without one back-edge or assignment, and each call
    has fresh locals, so the measured call's observer state is its own."""
    st = steps(row, xs, c)
    aff = [s for s in st if s[0] == "aff"]
    zero = 0 if row["gen"].get("int") else 0.0
    out = table("OPS", [0 if s[0] == "set" else 1 for s in st])
    out += table("A", [zero if s[0] == "set" else s[1] for s in st] if aff else [])
    out += table("B", [s[1] if s[0] == "set" else s[2] for s in st])
    out += table("YB", ys[:c + 1]) if ys is not None else []
    out += ["OUT is []", "OUTY is []", "define run_row(m) as:", "    i is 0", "    loop while i < m:",
            "        if OPS[i] == 0:", "            x is B[i]", "        else:",
            "            x is x * A[i] + B[i]", "        append of [OUT, x]"]
    out += ["        y is YB[i]", "        append of [OUTY, y]"] if ys is not None else []
    out += ["        i is i + 1", "    if m > 0:", "        " + ck_line(c, ys), "    return 0",
            f"for k in range of {warm}:", "    r is run_row of 0", f"r is run_row of {c + 1}",
            "for k in range of (len of OUT):", '    print of f"V {k} {OUT[k]}"',
            "for k in range of (len of OUTY):", '    print of f"Y {k} {OUTY[k]}"',
            f'print of "ROW_DONE {row["id"]}"']
    return "\n".join(out) + "\n"


# --- running ----------------------------------------------------------------

def check_value(rid, tag, i, want, tok, ieee):
    try:
        got = int(tok) if re.fullmatch(r"-?\d+", tok) else float(tok)
    except ValueError:
        raise HarnessError(f"{rid}: {tag}_{i} unparsable value {tok!r}")
    if isinstance(want, int):
        if not (float(got).is_integer() and int(got) == want):
            raise HarnessError(f"{rid}: {tag}_{i} runtime={tok} generator={want} (ints must agree exactly)")
    elif math.isfinite(want):
        if struct.pack("<d", float(got)) != struct.pack("<d", want):
            raise HarnessError(f"{rid}: {tag}_{i} runtime={tok} generator={want!r}"
                               " (values must agree in every bit)")
    elif ieee:
        if not (got == want or (math.isnan(want) and math.isnan(got))):
            raise HarnessError(f"{rid}: {tag}_{i} generator={want!r}, runtime={tok} (IEEE mode)")
    elif got != math.copysign(CLAMP, want):
        raise HarnessError(f"{rid}: {tag}_{i} generator overflowed to {want!r},"
                           f" runtime={tok} (expected the clamp)")


def run(binary, prog, env):
    try:
        p = subprocess.run([binary, prog], capture_output=True, text=True, timeout=ROW_TIMEOUT,
                           stdin=subprocess.DEVNULL, env={**os.environ, **env})
    except (OSError, subprocess.TimeoutExpired) as e:
        raise HarnessError(f"{os.path.basename(prog)}: cannot run {binary}: {e}")
    hot = HOT_BLOCK.search(p.stderr)
    errors = [ln for ln in HOT_BLOCK.sub("", p.stderr).splitlines()
              if ln.strip() and not DIAG_LINE.match(ln)]
    return p.returncode, p.stdout.splitlines(), errors, p.stderr, hot.group(0) if hot else ""


def parse_run(row, cks, form, rc, lines, errors, xs, ys, ieee):
    rid = row["id"]
    if rc != 0 or errors or not lines or lines[-1] != f"ROW_DONE {rid}":
        raise HarnessError(f"{rid}: program failed (rc={rc})\nstderr: {' | '.join(errors)[:400]}\n"
                           f"stdout tail: {lines[-3:]}")
    got, vals, last = {}, {"V": {}, "Y": {}}, {"V": -1, "Y": -1}
    for ln in lines[:-1]:
        f = ln.split()
        if len(f) == 3 and f[0] in vals:
            i = int(f[1])
            if i != last[f[0]] + 1:
                raise HarnessError(f"{rid}: {f[0]} line {i} out of order after {last[f[0]]}")
            last[f[0]], vals[f[0]][i] = i, f[2]
            continue
        if len(f) != 9 + (ys is not None) or f[0] != "CK":
            raise HarnessError(f"{rid}: unexpected output line {ln!r}")
        at = int(f[1])
        if at in got:
            raise HarnessError(f"{rid}: duplicate checkpoint {at}")
        if form == "straight" and (last["V"] != at or (ys is not None and last["Y"] != at)):
            raise HarnessError(f"{rid}: checkpoint {at} read after value {last['V']}:"
                               " a read must follow the assignment of x_at")
        if any(w != str(at + 1) for w in f[8:]):
            raise HarnessError(f"{rid}: checkpoint {at} read after {f[8:]} assignments,"
                               f" not {at + 1}: a read must fall between x_at and x_{at + 1}")
        if any(b not in ("true", "false") for b in f[2:8]):
            raise HarnessError(f"{rid}@{at}: non-boolean read {f[2:8]}")
        got[at] = dict(zip(PREDS, (b == "true" for b in f[2:8])))
    if sorted(got) != cks:
        raise HarnessError(f"{rid}: checkpoints read {sorted(got)}, expected {cks}")
    upto = row["n"] if form == "straight" else cks[-1]
    for tag, seq in (("V", xs), ("Y", ys)):
        if seq is None:
            continue
        if sorted(vals[tag]) != list(range(upto + 1)):
            raise HarnessError(f"{rid}: {len(vals[tag])} {tag} values read, expected {upto + 1}")
        for i in range(upto + 1):
            check_value(rid, tag, i, seq[i], vals[tag][i], ieee)
    return got


def native(tier, rid, err, hot, m):
    """(native iterations of the measured call's m, what covered the loop)."""
    hrow = next((f for f in (ln.split() for ln in hot.splitlines()) if f[:1] == ["run_row"]), None)
    sec = re.search(r"^=== [^\n]*\(run_row, [^\n]*\n((?:\d{4,} [^\n]*\n?)*)", err, re.M)
    jbs = re.findall(r"^(\d{4,}) \[L\d+\] JUMP_BACK\s+(\d+)", sec.group(1), re.M) if sec else []
    if hrow is None or len(hrow) != 12 or len(jbs) != 1:
        raise HarnessError(f"{rid}: {tier} tier: no EIGS_JIT_HOT row for run_row, or not exactly"
                           " one loop in its EIGS_DUMP_BC listing; cannot measure the native share")
    jb = int(jbs[0][0])
    head, bked = jb + 3 - int(jbs[0][1]), int(hrow[7])
    thunks = [tuple(map(int, t)) for t in
              re.findall(r"^\[jit\] compiled run_row: entry=(\d+) prefix=(\d+)", err, re.M)]
    if tier == "jit":       # the function thunk spans the loop: interpreted back-edges are the rest
        ok = any(e == 0 and p > jb for e, p in thunks)
        nat, what = m - bked, f"function thunk stops at {hrow[11]}"
    else:                   # an OSR thunk spans the body [head, jb): one entry per back-edge
        ok = any(e == head and p == jb for e, p in thunks)
        nat, what = bked - 1, "an OSR thunk spans the loop body"
    return (max(0, min(m, nat)), what) if ok else (0, "no thunk spans the loop")


def probe(binary, code):
    try:
        p = subprocess.run([binary, "-e", code], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise HarnessError(f"cannot probe {binary}: {e}")
    return p.stdout.strip()


def capabilities(binary, asked):
    out = {k: probe(binary, c) for k, c in PROBES.items()}
    mode = {"inf": "ieee", "1e+308": "clamp"}.get(out["numbers"])
    if mode is None:
        raise HarnessError(f"number probe `{PROBES['numbers']}` printed {out['numbers']!r}, not inf or 1e+308")
    if asked and asked != mode:
        raise HarnessError(f"--numbers {asked} contradicts the binary: the probe printed {out['numbers']!r}")
    return mode == "ieee", {k: out[k] == HAS[k] for k in HAS}, out


def measure(binary, corpus, caps, ieee):
    """Run every row the binary can run in every arm: readings, held values,
    native shares and compile stops; capability skips are listed."""
    res = {"read": {}, "held": {}, "share": {t: [0, 0, 1.0] for t in ("jit", "osr")},
           "stops": {}, "skipped": [], "runs": 0}
    with tempfile.TemporaryDirectory(prefix="obs_oracle_") as tmp:
        for row in corpus["rows"]:
            rid, cap = row["id"], row.get("capability")
            if cap and not caps[cap]:
                res["skipped"].append((rid, cap))
                continue
            xs = generate(row["gen"], row["n"])
            ys = generate(row["second"], row["n"]) if "second" in row else None
            jobs = [("interp", "straight", row["checkpoints"], emit_straight(row, xs, ys))]
            jobs += [(t, "loop", [c], emit_loop(row, xs, ys, c, WARMUP[t]))
                     for c in row["checkpoints"] for t in TIERS]
            for tier, form, cks, text in jobs:
                prog = os.path.join(tmp, f"{rid}@{cks[-1]}.{tier}.{form}.eigs")
                with open(prog, "w") as f:
                    f.write(text)
                rc, lines, errors, err, hot = run(binary, prog, {**TIERS[tier], **(DIAG if tier != "interp" else {})})
                got = parse_run(row, cks, form, rc, lines, errors, xs, ys, ieee)
                res["runs"] += 1
                if tier != "interp":
                    m = cks[0] + 1
                    nat, stop = native(tier, rid, err, hot, m)
                    sh = res["share"][tier]
                    sh[0], sh[1], sh[2] = sh[0] + nat, sh[1] + m, min(sh[2], nat / m)
                    res["stops"][(tier, stop)] = res["stops"].get((tier, stop), 0) + 1
                for at in cks:
                    for p in PREDS:
                        res["read"][(tier, form, rid, at, p)] = got[at][p]
            # The reference arms see the values the RUNTIME held: the clamp, or IEEE inf/NaN.
            res["held"][rid] = [float(x) if ieee or math.isnan(x) else max(-CLAMP, min(CLAMP, float(x)))
                                for x in xs]
    examined = len({k[2] for k in res["read"]})
    if examined + len(res["skipped"]) != len(corpus["rows"]) or examined == 0:
        raise HarnessError(f"examined {examined} rows + {len(res['skipped'])} skipped of {len(corpus['rows'])}")
    return res


# --- scoring ----------------------------------------------------------------

def verdicts(res, corpus, labels):
    """(arm, rid, at, pred) -> (class, label, reading) for every scored
    verdict, the runtime arms and the two reference arms."""
    out, rows = {}, {r["id"]: r for r in corpus["rows"]}
    for (tier, form, rid, at, p), got in res["read"].items():
        e = labels[f"{rid}@{at}"][p]
        out[(f"{tier}/{form}", rid, at, p)] = (e[0], e[1], got)
    for rid, held in res["held"].items():
        hs = reference.entropy_signal(held)
        for at in rows[rid]["checkpoints"]:
            lab = labels[f"{rid}@{at}"]
            for arm, sig in (("REFERENCE", held), ("REFERENCE_ENTROPY", hs)):
                ref = reference.classify(sig, at)
                for p in PREDS:
                    out[(arm, rid, at, p)] = (lab[p][0], lab[p][1], ref[p])
    declared = sum(len(r["checkpoints"]) for r in corpus["rows"] if r["id"] in res["held"]) * len(PREDS)
    for arm in [f"{t}/{f}" for t, f in ARMS] + ["REFERENCE", "REFERENCE_ENTROPY"]:
        if sum(1 for k in out if k[0] == arm) != declared or declared == 0:
            raise HarnessError(f"{arm} scored {sum(1 for k in out if k[0] == arm)} verdicts, corpus declares {declared}")
    return out


def right_set(v, rows, capability):
    """The runtime verdicts the binary got right, keyed as floor.json keys them."""
    return sorted(f"{arm} {rid}@{at} {p} {cls}" for (arm, rid, at, p), (cls, want, got) in v.items()
                  if "/" in arm and want == got and bool(rows[rid].get("capability")) == capability)


def check_floor(path, cand_v, rows, corpus, labels):
    """1 when a floor verdict is now wrong without a waiver, 0 otherwise;
    HarnessError when the floor or its waivers cannot be trusted."""
    try:
        with open(path) as f:
            floor = json.load(f)
        with open(os.path.join(os.path.dirname(os.path.abspath(path)), "waivers.json")) as f:
            waivers = json.load(f)["waivers"]
    except (OSError, ValueError, KeyError) as e:
        raise HarnessError(f"cannot load the floor or its waivers.json: {e}")
    fb = floor.get("binary", {})
    if floor.get("format") != FLOOR_FORMAT or not isinstance(floor.get("verdicts"), list):
        raise HarnessError(f"floor {path}: not a {FLOOR_FORMAT} floor")
    if not (os.path.isfile(fb.get("path", "")) and sha256(fb["path"]) == fb.get("sha256")):
        raise HarnessError(f"floor binary {fb.get('path')} is missing or no longer has sha256 {fb.get('sha256')}")
    ieee, caps, _ = capabilities(fb["path"], None)
    fv = verdicts(measure(fb["path"], corpus, caps, ieee), corpus, labels)
    want = right_set(fv, rows, False)
    extra, missing = sorted(set(floor["verdicts"]) - set(want)), sorted(set(want) - set(floor["verdicts"]))
    if extra or missing or len(floor["verdicts"]) != len(want):
        raise HarnessError(f"floor {path} does not match its own measurement on {fb['path']}:"
                           f" {len(extra)} listed verdict(s) that binary gets wrong (first {extra[:1]}),"
                           f" {len(missing)} right one(s) missing (first {missing[:1]}); re-write it with --write-floor")
    stale = [k for k, h in floor.get("inputs", {}).items() if os.path.isfile(os.path.join(HERE, k)) and sha256(os.path.join(HERE, k)) != h]
    print(f"\nfloor: {len(want)} verdicts ({FLOOR_FORMAT}), re-measured on {fb['path']}: the list matches"
          + (f" (recorded before edits to {', '.join(stale)})" if stale else ""))
    cand = {f"{arm} {rid}@{at} {p} {cls}": want_ == got for (arm, rid, at, p), (cls, want_, got) in cand_v.items()
            if "/" in arm}
    wv = {}
    for w in waivers:
        if not isinstance(w, dict) or not str(w.get("reason", "")).strip():
            raise HarnessError(f"waiver {w!r} has no reason: a waiver says why the new verdict is more correct")
        if w.get("verdict") not in floor["verdicts"] or w["verdict"] in wv:
            raise HarnessError(f"waiver for {w.get('verdict')!r}: not a floor verdict, or named twice")
        wv[w["verdict"]] = w["reason"]
    lost = [k for k in floor["verdicts"] if not cand[k]]
    unused = sorted(set(wv) - set(lost))
    if unused:
        raise HarnessError(f"waiver for {unused[0]}, which this binary gets right: remove it ({len(unused)} unused)")
    bad = [k for k in lost if k not in wv]
    for k in lost:
        print(f"  FLOOR {'WAIVED' if k in wv else 'VIOLATION'} {k}" + (f": {wv[k]}" if k in wv else ""))
    print(f"floor: {len(floor['verdicts'])} verdicts checked, {len(bad)} lost, {len(lost) - len(bad)} waived")
    return 1 if bad else 0


def report(v, res, corpus, numbers, caps, probes, labels, reported):
    arms = [f"{t}/{f}" for t, f in ARMS] + ["REFERENCE", "REFERENCE_ENTROPY"]
    scored = derive.scored_classes(corpus)[0]
    print(f"observer oracle: {len(corpus['rows'])} rows, {len(res['held'])} run, {len(res['skipped'])} skipped"
          f" by capability; {res['runs']} programs; numbers={numbers}")
    for cap in sorted(HAS):
        n = sum(1 for _r, c in res["skipped"] if c == cap)
        total = sum(1 for r in corpus["rows"] if r.get("capability") == cap)
        print(f"  capability {cap}: probe `{PROBES[cap]}` printed {probes[cap]!r}: "
              + ("present, " if caps[cap] else "ABSENT, ") + f"{total - n} row(s) run, {n} SKIPPED")
    print(f"\nnative assignment share of the measured loop (VACUOUS below {NATIVE_FLOOR:.0%}):")
    for t, (nat, m, lo) in res["share"].items():
        print(f"  {t}: {nat}/{m} = {nat / max(m, 1):.1%} (lowest run {lo:.1%}); run_row: "
              + ", ".join(f"{s} in {c} runs" for (tt, s), c in sorted(res["stops"].items()) if tt == t))
    print("  predicate reads run interpreted in every tier: PREDICATE_NAME stops compilation")
    print("\nSCORED VERDICTS, one question per predicate: TP FP FN TN right/total")
    print(f"  {'predicate':12}{'class':11}" + "".join(f"{a:>24}" for a in arms))
    for p in PREDS + ["all"]:
        cells = []
        for a in arms:
            c = [0, 0, 0, 0]
            for (arm, _r, _at, q), (_cls, want, got) in v.items():
                if arm == a and q in (p, *(PREDS if p == "all" else [])):
                    c[{(True, True): 0, (False, True): 1, (True, False): 2, (False, False): 3}[(want, got)]] += 1
            cells.append(f"{c[0]:3} {c[1]:3} {c[2]:3} {c[3]:3} {c[0] + c[3]:4}/{sum(c):<4}")
        print(f"  {p:12}{scored.get(p, '-'):11}" + "".join(f"{x:>24}" for x in cells))
    for col in reported.values():
        agree = [[labels[f"{rid}@{at}"][col][1] == got for (arm, rid, at, q), (_c, _w, got) in v.items()
                  if arm == a and q == "converged"] for a in arms]
        print(f"REPORTED, not scored: MATH {col} vs each arm's `converged`, agree/total: "
              + ", ".join(f"{a} {sum(n)}/{len(n)}" for a, n in zip(arms, agree)))
    head = [[x[1] == x[2] for k, x in v.items() if k[0] == a] for a in arms]
    print("HEADLINE, scored verdicts right/total (each verdict counted once): "
          + ", ".join(f"{a} {sum(h)}/{len(h)}" for a, h in zip(arms, head)))
    for a in ("interp/straight", "REFERENCE"):
        dis = [(k, x) for k, x in v.items() if k[0] == a and x[1] != x[2]]
        print(f"\n{a} disagreements ({len(dis)}):")
        for (_a, rid, at, p), (cls, want, got) in dis:
            print(f"  {rid}@{at} {p} {cls}: expected={str(want).lower()} actual={str(got).lower()}"
                  f"  {labels[f'{rid}@{at}'][p][3]}")


def main(argv):
    args, opts = argv[1:], {}
    for flag in ("--corpus", "--numbers", "--floor", "--write-floor", "--note"):
        if flag in args:
            i = args.index(flag)
            if i + 1 >= len(args):
                raise HarnessError(f"{flag} needs a value")
            opts[flag] = args[i + 1]
            del args[i:i + 2]
    if len(args) != 1 or opts.get("--numbers", "clamp") not in ("ieee", "clamp"):
        raise HarnessError("usage: score.py BINARY [--corpus PATH] [--numbers ieee|clamp]"
                           " [--floor FILE] [--write-floor FILE [--note TEXT]]")
    binary = os.path.abspath(args[0])
    if not (os.path.isfile(binary) and os.access(binary, os.X_OK)):
        raise HarnessError(f"binary not found or not executable: {binary}")
    corpus_path = opts.get("--corpus", os.path.join(HERE, "corpus.json"))
    cdir = os.path.dirname(os.path.abspath(corpus_path))
    corpus = derive.load_corpus(corpus_path)
    certs = derive.load_certificates(corpus, os.path.join(cdir, "certificate.json"))
    labels = load_labels(corpus, certs, os.path.join(cdir, "labels.json"))
    rows = {r["id"]: r for r in corpus["rows"]}
    ieee, caps, probes = capabilities(binary, opts.get("--numbers"))
    res = measure(binary, corpus, caps, ieee)
    v = verdicts(res, corpus, labels)
    report(v, res, corpus, "ieee" if ieee else "clamp", caps, probes, labels, derive.scored_classes(corpus)[1])
    vacuous = [f"{t} {nat / max(m, 1):.1%}" for t, (nat, m, _lo) in res["share"].items() if nat < NATIVE_FLOOR * m]
    if vacuous:
        raise HarnessError(f"VACUOUS tier(s): {', '.join(vacuous)} native assignment share,"
                           f" below the {NATIVE_FLOOR:.0%} floor; the tier did not run the loop natively")
    reads = {}
    for (arm, rid, at, p), (_c, _w, got) in v.items():
        if "/" in arm:
            reads.setdefault((rid, at, p), {})[arm] = got
    findings = [(k, r) for k, r in reads.items() if len(set(r.values())) > 1]
    print(f"\nFINDINGS (a reading that differs between arms; each one fails the run): {len(findings)}")
    for (rid, at, p), r in findings:
        print(f"  FINDING {rid}@{at} {p}: " + " ".join(f"{a}={str(b).lower()}" for a, b in r.items()))
    capwrong = [k for k, (cls, want, got) in v.items() if "/" in k[0] and rows[k[1]].get("capability") and want != got]
    ran = sorted({k[1] for k in v if rows[k[1]].get("capability")})
    print(f"\nCAPABILITY ROWS (every scored verdict must be right): {len(ran)} run, {len(res['skipped'])} skipped,"
          f" {len(capwrong)} wrong verdict(s)")
    for arm, rid, at, p in capwrong:
        print(f"  CAPABILITY WRONG {arm} {rid}@{at} {p}: expected={str(v[(arm, rid, at, p)][1]).lower()}")
    fail = 1 if findings or capwrong else 0
    if "--floor" in opts:
        fail |= check_floor(opts["--floor"], v, rows, corpus, labels)
    if "--write-floor" in opts:
        inputs = {k: sha256(os.path.join(HERE, k)) for k in ("gen.py", "derive.py", "score.py", "reference.py")}
        inputs.update({k: sha256(os.path.join(cdir, k)) for k in ("corpus.json", "labels.json", "certificate.json")})
        with open(opts["--write-floor"], "w") as f:
            json.dump({"format": FLOOR_FORMAT, "binary": {"path": binary, "sha256": sha256(binary)},
                       "note": opts.get("--note", ""), "numbers": "ieee" if ieee else "clamp",
                       "inputs": inputs, "verdicts": right_set(v, rows, False)}, f, indent=0)
            f.write("\n")
        print(f"floor written: {opts['--write-floor']}")
    print(f"\nobserver oracle exit {fail}: " + ("FAIL" if fail else "no gate failed"))
    return fail


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except HarnessError as e:
        print(f"OBSERVER_ORACLE_ERROR: {e}", file=sys.stderr)
        sys.exit(2)
    except Exception as e:          # an instrument crash is never a verdict
        print(f"OBSERVER_ORACLE_ERROR: internal {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(2)
