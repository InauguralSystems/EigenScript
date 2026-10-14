#!/usr/bin/env python3
"""Score EigenScript's observer against a ground-truth corpus (#1746, #1758).

usage: score.py BINARY [--corpus PATH] [--numbers ieee|clamp] [--expect CAP,...]
                       [--floor FILE] [--write-floor FILE [--note TEXT]]

labels.json must equal derive.py's derivation (the label gate). Each
predicate is scored against ONE question (converged, stable, improving:
CONVENTION; oscillating, diverging, equilibrium: MATH); MATH "has a limit"
and a MATH verdict read before its row's law last changes are REPORTED, never
scored. Each row runs on BINARY in four ARMS: interp/straight (straight-line
code), and a loop form per checkpoint in interp/loop (EIGS_JIT_OFF=1),
jit/loop (after 50 zero-iteration warm-up calls) and osr/loop
(EIGS_JIT_OSR_THRESHOLD=1). The loop (`loop while true`, x from a list or
x * a + b computed in the runtime) leaves by `break` after its body. Each
jit/osr run WITNESSES its own tier from EIGS_JIT_HOT and EIGS_DUMP_BC: native
when its thunk's last exit lies past the back-edge (jit: `adv`, and bked = 0;
osr: `oent + oadv`), which a body that bails cannot reach. A body that stops
computing x on a non-finite or clamped value is reported as interpreted and
not counted (the JIT's designed bail, #1758 N12); any other non-native run is
VACUOUS (exit 2). No aggregate. Predicate reads always run interpreted.
Values are compared with the generator's exactly, and each read must fall
between x_c and x_{c+1} (`when is x`). A capability row runs only when a
semantic probe shows the capability; a skip warns, and an --expect'ed
capability that is absent fails. The reference model (reference.py, distance
and the runtime's entropy signal, #1667) shares the observer's window and
tolerances, so it is correlated with the runtime, not independent evidence.

Exit 1: a FINDING (a reading that differs between arms), a wrong verdict on a
capability row, an expected capability absent, or (--floor) a floor verdict
now wrong. There are no waivers: a floor verdict agrees with its label, so
losing it is wrong unless the label is, and a wrong label is fixed through
derive/certify, which re-measures the floor. The floor's anchor is the binary
build_anchor.sh builds from tag v0.46.0: --floor re-measures it every run and
refuses a floor that is not its measurement; --write-floor refuses any other
binary. Exit 2 on any harness error (a failing program, a bad output line, a
value off the generator, a VACUOUS run, stale certificates or labels, a
refused floor, an internal exception).
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
DIAG = {"EIGS_JIT_HOT": "1", "EIGS_DUMP_BC": "1"}
PROBES = {"numbers": "print of (1e308 * 10)", "true": "print of (1 == 1)",
          "ieee": "y is 0.0 / 0.0\nprint of (y != y)",
          "int64": "print of ((9223372036854775807 - 9223372036854775806) == 1)",  # 0 in doubles
          "int64_kind": "print of (num_type of 9223372036854775807)"}
CAPS = ("ieee", "int64")
FLOOR_FORMAT = "per-verdict/2"
RECIPE = os.path.join(HERE, "build_anchor.sh")
HOT_BLOCK = re.compile(r"=== Hot chunks.*?\n  bytes native: [^\n]*", re.S)
DIAG_LINE = re.compile(r"^(=== .* ===$|\d{4,} \[L\d+\] )")


def read_expr(pred):
    """The one place a predicate read is spelled (per-variable form)."""
    return f"{pred} of x"


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def load_labels(corpus, certs, path):
    """The label gate: labels.json must equal derive(corpus), whose own
    postconditions hold (one entry per predicate, the regime rule, the lattice)."""
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
    """run_row(m) makes the first m assignments in a `loop while true` the
    function JIT compiles (B[i], or x * A[i] + B[i] in the runtime), records
    them in OUT and leaves by `break` AFTER the body, so the last thunk exit
    of a body that ran natively lies past the back-edge; then it reads
    checkpoint c. `warm` calls with m = 0 come first: they compile run_row
    without one back-edge or assignment, and each call has fresh locals, so
    the measured call's observer state is its own."""
    st = steps(row, xs, c)
    aff = [s for s in st if s[0] == "aff"]
    zero = 0 if row["gen"].get("int") else 0.0
    out = table("OPS", [0 if s[0] == "set" else 1 for s in st])
    out += table("A", [zero if s[0] == "set" else s[1] for s in st] if aff else [])
    out += table("B", [s[1] if s[0] == "set" else s[2] for s in st])
    out += table("YB", ys[:c + 1]) if ys is not None else []
    out += ["OUT is []", "OUTY is []", "define run_row(m) as:", "    i is 0", "    if m > 0:",
            "        loop while true:", "            if OPS[i] == 0:", "                x is B[i]",
            "            else:", "                x is x * A[i] + B[i]", "            append of [OUT, x]"]
    out += ["            y is YB[i]", "            append of [OUTY, y]"] if ys is not None else []
    out += ["            i is i + 1", "            if i >= m:", "                break",
            "        " + ck_line(c, ys), "    return 0",
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


def witness(tier, rid, err, hot, held, c):
    """("native" | "value bail" | "VACUOUS", detail) for the measured call's
    loop. Its thunk's last exit must lie past the loop's back-edge (the body
    ran to its `break` natively); for the function thunk also bked = 0, since
    after a bail the rest of the call runs interpreted. A stop INSIDE the
    computation of x (from the body's MUL to the next OBSERVE_ASSIGN) on a
    non-finite or clamped value is the JIT's designed bail (#1758 N12)."""
    hrow = next((f for f in (ln.split() for ln in hot.splitlines()) if f[:1] == ["run_row"]), None)
    sec = re.search(r"^=== [^\n]*\(run_row, [^\n]*\n((?:\d{4,} [^\n]*\n?)*)", err, re.M)
    ops = {int(o): (op, arg) for o, op, arg in
           re.findall(r"^(\d{4,}) \[L\d+\] (\S+) *(\S*)", sec.group(1), re.M)} if sec else {}
    jbs = [o for o, (op, _a) in ops.items() if op == "JUMP_BACK"]
    if hrow is None or len(hrow) != 12 or len(jbs) != 1:
        raise HarnessError(f"{rid}@{c}: {tier} tier: no EIGS_JIT_HOT row for run_row, or not exactly"
                           " one loop in its EIGS_DUMP_BC listing; cannot witness the tier")
    jb, bked = jbs[0], int(hrow[7])
    if tier == "jit":
        at = int(hrow[4]) if hrow[2] == "yes" and hrow[4].isdigit() else -1
        ok, k = at > jb and bked == 0, c - bked       # x_k is the value whose iteration bailed
    else:
        head = jb + 3 - int(ops[jb][1])
        at = int(hrow[10]) + int(hrow[9]) if hrow[8] == "yes" and int(hrow[10]) == head else -1
        ok, k = at > jb, c
    stop = f"{ops[at][0]}@{at}" if at in ops else "no thunk"
    if ok:
        return "native", f"exits at {stop}, past the back-edge at {jb}"
    mul = min((o for o, (op, _a) in ops.items() if op == "MUL" and o < jb), default=jb)
    asg = min((o for o, (op, _a) in ops.items() if op.startswith("OBSERVE_ASSIGN") and o > mul), default=mul)
    bad = [v for v in held[max(0, k - 1):k + 1] if not math.isfinite(v) or abs(v) >= CLAMP]
    if bad and mul <= at <= asg:
        return "value bail", f"stops at {stop}, computing x, on x = {bad[-1]!r}"
    return "VACUOUS", f"stops at {stop} (bked={bked}), not on a non-finite value computing x"


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
    if not out["true"]:
        raise HarnessError(f"`{PROBES['true']}` printed nothing: the capability probes have no true to compare")
    caps = {"ieee": out["ieee"] == out["true"],
            "int64": out["int64"] == out["true"] and out["int64_kind"] == "int"}
    return mode == "ieee", caps, out


def measure(binary, corpus, caps, ieee):
    """Run every row the binary can run in every arm: readings, held values
    and per-run tier witnesses; capability skips are listed."""
    res = {"read": {}, "held": {}, "wit": {}, "skipped": [], "runs": 0}
    with tempfile.TemporaryDirectory(prefix="obs_oracle_") as tmp:
        for row in corpus["rows"]:
            rid, cap = row["id"], row.get("capability")
            if cap and not caps[cap]:
                res["skipped"].append((rid, cap))
                continue
            xs = generate(row["gen"], row["n"])
            ys = generate(row["second"], row["n"]) if "second" in row else None
            # The values the RUNTIME holds: the clamp, or IEEE inf/NaN.
            held = res["held"][rid] = [float(x) if ieee or math.isnan(x)
                                       else max(-CLAMP, min(CLAMP, float(x))) for x in xs]
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
                    res["wit"][(tier, rid, cks[0])] = witness(tier, rid, err, hot, held, cks[0])
                for at in cks:
                    for p in PREDS:
                        res["read"][(tier, form, rid, at, p)] = got[at][p]
    examined = len({k[2] for k in res["read"]})
    if examined + len(res["skipped"]) != len(corpus["rows"]) or examined == 0:
        raise HarnessError(f"examined {examined} rows + {len(res['skipped'])} skipped of {len(corpus['rows'])}")
    return res


# --- scoring ----------------------------------------------------------------

def verdicts(res, corpus, labels):
    """(arm, rid, at, pred) -> (class, label, reading) for every SCORED
    verdict, the runtime arms and the two reference arms (REPORTED skipped)."""
    out, rows = {}, {r["id"]: r for r in corpus["rows"]}
    for (tier, form, rid, at, p), got in res["read"].items():
        e = labels[f"{rid}@{at}"][p]
        if e[0] != "REPORTED":
            out[(f"{tier}/{form}", rid, at, p)] = (e[0], e[1], got)
    for rid, held in res["held"].items():
        hs = reference.entropy_signal(held)
        for at in rows[rid]["checkpoints"]:
            lab = labels[f"{rid}@{at}"]
            for arm, sig in (("REFERENCE", held), ("REFERENCE_ENTROPY", hs)):
                ref = reference.classify(sig, at)
                for p in PREDS:
                    if lab[p][0] != "REPORTED":
                        out[(arm, rid, at, p)] = (lab[p][0], lab[p][1], ref[p])
    declared = sum(1 for rid in res["held"] for at in rows[rid]["checkpoints"]
                   for p in PREDS if labels[f"{rid}@{at}"][p][0] != "REPORTED")
    for arm in [f"{t}/{f}" for t, f in ARMS] + ["REFERENCE", "REFERENCE_ENTROPY"]:
        if sum(1 for k in out if k[0] == arm) != declared or declared == 0:
            raise HarnessError(f"{arm} scored {sum(1 for k in out if k[0] == arm)} verdicts, corpus declares {declared}")
    return out


def right_set(v, rows):
    """The runtime verdicts the binary got right on rows with no capability,
    keyed as floor.json keys them."""
    return sorted(f"{arm} {rid}@{at} {p} {cls}" for (arm, rid, at, p), (cls, want, got) in v.items()
                  if "/" in arm and want == got and not rows[rid].get("capability"))


def anchor():
    """The stamp build_anchor.sh wrote beside the binary it built, checked
    against the recipe as it stands and the binary as it is."""
    d = re.search(r"^DIR=(\S+)", open(RECIPE).read(), re.M).group(1)
    try:
        with open(os.path.join(d, "anchor.json")) as f:
            stamp = json.load(f)
    except (OSError, ValueError):
        raise HarnessError(f"no floor anchor at {d}: run bash tools/observer_oracle/build_anchor.sh")
    if stamp.get("recipe_sha256") != sha256(RECIPE) or not os.path.isfile(stamp.get("binary", "")) \
            or sha256(stamp["binary"]) != stamp.get("binary_sha256"):
        raise HarnessError(f"the anchor at {d} is not what build_anchor.sh as it stands builds:"
                           " re-run bash tools/observer_oracle/build_anchor.sh")
    return stamp


def check_floor(path, cand_v, rows, corpus, labels):
    """1 when a floor verdict is now wrong, 0 otherwise; HarnessError when the
    floor cannot be trusted: not measured on the recipe's anchor, or not that
    anchor's measurement now."""
    if os.path.exists(os.path.join(os.path.dirname(os.path.abspath(path)), "waivers.json")):
        raise HarnessError("waivers.json: waivers are removed by design. A floor verdict agrees with its"
                           " label, so an observer that loses it is wrong unless the label is; fix a wrong"
                           " label through derive.py/certify.py, which re-measures the floor")
    try:
        with open(path) as f:
            floor = json.load(f)
    except (OSError, ValueError) as e:
        raise HarnessError(f"cannot load the floor {path}: {e}")
    fa, stamp = floor.get("anchor", {}), anchor()
    if floor.get("format") != FLOOR_FORMAT or not isinstance(floor.get("verdicts"), list):
        raise HarnessError(f"floor {path}: not a {FLOOR_FORMAT} floor")
    if fa.get("recipe_sha256") != stamp["recipe_sha256"] or fa.get("binary_sha256") != stamp["binary_sha256"]:
        raise HarnessError(f"floor {path} was measured on another anchor (recipe {fa.get('recipe_sha256')},"
                           f" binary {fa.get('binary_sha256')}); the recipe now builds {stamp['binary_sha256']}")
    ieee, caps, _ = capabilities(stamp["binary"], None)
    want = right_set(verdicts(measure(stamp["binary"], corpus, caps, ieee), corpus, labels), rows)
    extra, missing = sorted(set(floor["verdicts"]) - set(want)), sorted(set(want) - set(floor["verdicts"]))
    if extra or missing or len(floor["verdicts"]) != len(want):
        raise HarnessError(f"floor {path} is not its anchor's measurement: {len(extra)} listed verdict(s)"
                           f" the anchor gets wrong (first {extra[:1]}), {len(missing)} right one(s) missing"
                           f" (first {missing[:1]}); the corpus, labels or harness changed: re-measure"
                           f" with score.py {stamp['binary']} --write-floor {path}")
    print(f"\nfloor: {len(want)} verdicts ({FLOOR_FORMAT}), re-measured on the anchor {stamp['binary']}"
          f" (sha256 {stamp['binary_sha256'][:12]}, built by build_anchor.sh): the list matches")
    cand = {f"{arm} {rid}@{at} {p} {cls}": w == g for (arm, rid, at, p), (cls, w, g) in cand_v.items() if "/" in arm}
    lost = [k for k in floor["verdicts"] if not cand[k]]
    for k in lost:
        print(f"  FLOOR VIOLATION {k}")
    print(f"floor: {len(floor['verdicts'])} verdicts checked, {len(lost)} lost")
    return 1 if lost else 0


def report(v, res, corpus, numbers, caps, probes, labels, reported, expect):
    arms = [f"{t}/{f}" for t, f in ARMS] + ["REFERENCE", "REFERENCE_ENTROPY"]
    scored = derive.scored_classes(corpus)[0]
    print(f"observer oracle: {len(corpus['rows'])} rows, {len(res['held'])} run, {len(res['skipped'])} skipped"
          f" by capability; {res['runs']} programs; numbers={numbers}")
    for cap in CAPS:
        n = sum(1 for _r, c in res["skipped"] if c == cap)
        line = (f"capability {cap}: probe printed {probes[cap]!r}"
                + (f", num_type {probes['int64_kind']!r}" if cap == "int64" else "") + f" (true is {probes['true']!r}): ")
        if caps[cap]:
            print(f"  {line}present, {sum(1 for r in corpus['rows'] if r.get('capability') == cap)} row(s) run")
        else:
            print(f"  {'EXPECTED ' if cap in expect else 'WARNING: '}{line}ABSENT, {n} row(s) SKIPPED")
    print("\nTIER WITNESS, per run (n native, v interpreted: a value bail on a non-finite or clamped value, V VACUOUS):")
    for row in corpus["rows"]:
        if row["id"] in res["held"]:
            print(f"  {row['id']:22}" + " ".join(
                f"@{c} jit:{res['wit'][('jit', row['id'], c)][0][0]} osr:{res['wit'][('osr', row['id'], c)][0][0]}"
                for c in row["checkpoints"]))
    for t in ("jit", "osr"):
        w = {k[1:]: x for k, x in res["wit"].items() if k[0] == t}
        print(f"  {t}: {sum(1 for x in w.values() if x[0] == 'native')} of {len(w)} runs witness a native body;"
              f" minimum: every run that is not a value bail, and at least one")
        for (rid, c), (status, detail) in w.items():
            if status != "native":
                print(f"    {status.upper() if status == 'VACUOUS' else 'interpreted (value bail)'} {t}"
                      f" {rid}@{c}: {detail}")
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
    head = [[x[1] == x[2] for k, x in v.items() if k[0] == a] for a in arms]
    print("HEADLINE, scored verdicts right/total (each verdict counted once): "
          + ", ".join(f"{a} {sum(h)}/{len(h)}" for a, h in zip(arms, head)))
    for col in reported.values():
        agree = [[labels[f"{rid}@{at}"][col][1] == got for (arm, rid, at, q), (_c, _w, got) in v.items()
                  if arm == a and q == "converged"] for a in arms]
        print(f"REPORTED, not scored: MATH {col} vs each arm's `converged`, agree/total: "
              + ", ".join(f"{a} {sum(n)}/{len(n)}" for a, n in zip(arms, agree)))
    early = sorted(f"{rid}@{at} {p}" for rid in res["held"] for at in
                   next(r["checkpoints"] for r in corpus["rows"] if r["id"] == rid)
                   for p in PREDS if labels[f"{rid}@{at}"][p][0] == "REPORTED")
    print(f"REPORTED, not scored: MATH verdicts read before their row's law last changes: {early or 'none'}")
    for a in ("interp/straight", "REFERENCE"):
        dis = [(k, x) for k, x in v.items() if k[0] == a and x[1] != x[2]]
        print(f"\n{a} disagreements ({len(dis)}):")
        for (_a, rid, at, p), (cls, want, got) in dis:
            print(f"  {rid}@{at} {p} {cls}: expected={str(want).lower()} actual={str(got).lower()}"
                  f"  {labels[f'{rid}@{at}'][p][3]}")


def main(argv):
    args, opts = argv[1:], {}
    for flag in ("--corpus", "--numbers", "--expect", "--floor", "--write-floor", "--note"):
        if flag in args:
            i = args.index(flag)
            if i + 1 >= len(args):
                raise HarnessError(f"{flag} needs a value")
            opts[flag] = args[i + 1]
            del args[i:i + 2]
    expect = set(filter(None, opts.get("--expect", "").split(",")))
    if len(args) != 1 or opts.get("--numbers", "clamp") not in ("ieee", "clamp") or expect - set(CAPS):
        raise HarnessError("usage: score.py BINARY [--corpus PATH] [--numbers ieee|clamp] [--expect ieee,int64]"
                           " [--floor FILE] [--write-floor FILE [--note TEXT]]")
    binary = os.path.abspath(args[0])
    if not (os.path.isfile(binary) and os.access(binary, os.X_OK)):
        raise HarnessError(f"binary not found or not executable: {binary}")
    if "--write-floor" in opts and os.path.realpath(binary) != os.path.realpath(anchor()["binary"]):
        raise HarnessError(f"--write-floor measures only the anchor build_anchor.sh builds"
                           f" ({anchor()['binary']}), not {binary}")
    corpus_path = opts.get("--corpus", os.path.join(HERE, "corpus.json"))
    cdir = os.path.dirname(os.path.abspath(corpus_path))
    corpus = derive.load_corpus(corpus_path)
    certs = derive.load_certificates(corpus, os.path.join(cdir, "certificate.json"))
    labels = load_labels(corpus, certs, os.path.join(cdir, "labels.json"))
    rows = {r["id"]: r for r in corpus["rows"]}
    ieee, caps, probes = capabilities(binary, opts.get("--numbers"))
    res = measure(binary, corpus, caps, ieee)
    v = verdicts(res, corpus, labels)
    report(v, res, corpus, "ieee" if ieee else "clamp", caps, probes, labels,
           derive.scored_classes(corpus)[1], expect)
    vacuous = [f"{t} {rid}@{c}: {d}" for (t, rid, c), (s, d) in res["wit"].items() if s == "VACUOUS"]
    if vacuous or not all(any(k[0] == t and x[0] == "native" for k, x in res["wit"].items()) for t in ("jit", "osr")):
        raise HarnessError(f"VACUOUS: {len(vacuous)} JIT-tier run(s) did not run their loop body natively"
                           f" and stopped on finite values, first {vacuous[:1]}; or a tier witnessed no run")
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
    missing = sorted(c for c in expect if not caps[c])
    print(f"\nCAPABILITY ROWS (every scored verdict must be right): {len(ran)} run, {len(res['skipped'])} skipped,"
          f" {len(capwrong)} wrong verdict(s); expected and absent: {missing or 'none'}")
    for arm, rid, at, p in capwrong:
        print(f"  CAPABILITY WRONG {arm} {rid}@{at} {p}: expected={str(v[(arm, rid, at, p)][1]).lower()}")
    fail = 1 if findings or capwrong or missing else 0
    if "--floor" in opts:
        fail |= check_floor(opts["--floor"], v, rows, corpus, labels)
    if "--write-floor" in opts:
        stamp = anchor()
        with open(opts["--write-floor"], "w") as f:
            json.dump({"format": FLOOR_FORMAT, "note": opts.get("--note", ""), "numbers": "ieee" if ieee else "clamp",
                       "anchor": {k: stamp[k] for k in ("tag", "commit", "binary", "binary_sha256", "recipe_sha256")},
                       "verdicts": right_set(v, rows)}, f, indent=0)
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
