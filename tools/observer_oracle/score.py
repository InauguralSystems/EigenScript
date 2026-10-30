#!/usr/bin/env python3
"""Score EigenScript's observer against a ground-truth corpus (#1746, #1758).

usage: score.py BINARY [--corpus PATH] [--numbers ieee|clamp] [--expect CAP,...]
                       [--floor FILE] [--declared FILE] [--write-floor FILE [--note TEXT]]

labels.json must equal derive.py's derivation (the label gate). Each
predicate is scored against ONE question (converged, stable, improving:
CONVENTION; oscillating, diverging, equilibrium: MATH; at a checkpoint whose
value is NaN every predicate answers the #1758 NaN convention, CONVENTION);
MATH "has a limit" and a MATH verdict read before its row's law last changes
are REPORTED, never scored. Each row runs on BINARY in four ARMS, each with
every inherited EIGS_* variable scrubbed and only its own set:
interp/straight, module-level straight-line code, where x is a NAME
(OBSERVE_ASSIGN, PREDICATE_NAME); and a loop form per checkpoint in
interp/loop (EIGS_JIT_OFF=1), jit/loop (after 50 zero-iteration warm-up
calls) and osr/loop (EIGS_JIT_OSR_THRESHOLD=1), where x is a function local
in a SLOT (OBSERVE_ASSIGN_LOCAL, PREDICATE_SLOT). Every run's EIGS_DUMP_BC
listing must show the path its arm grades (the opcode gate). The loop
(`loop while true`, x from a list or x * a + b computed in the runtime)
leaves by `break` after its body. Each jit/osr run WITNESSES its own tier
from EIGS_JIT_HOT and EIGS_DUMP_BC. jit: the function thunk's last exit lies
past the loop's back-edge (`adv`, RET included) and bked = 0, so every
iteration's body ran natively, x_0's assignment included. osr: the OSR
thunk's LAST exit lies past the back-edge (`oent + oadv`), which covers the
last iteration's body only: OSR compiles at the first back-edge, so x_0 is
always assigned interpreted, and an earlier iteration that bailed is
unwitnessed until #1768. Value-bail exemption: a run whose thunk stops
computing x (from the body's MUL to its OBSERVE_ASSIGN) on an inf, NaN or
clamped value (the JIT's designed bail, #1758 N12) is reported as
interpreted and passes, so its readings grade the interpreted observer for
the bailed iterations. Int64 capability rows retain exact int literals;
until R5 their JIT-enabled runs may explicitly witness an interpreted int
opcode refusal (INT_* before observing x; no function thunk, and OSR
absent or its actual prefix exit at that int opcode).
All floor rows use float scaffolding and float recurrence operands, as on
the pinned pre-int anchor; every other non-native run is VACUOUS (exit 2). No
aggregate. Predicate reads always run interpreted: the JIT compiles neither
PREDICATE_SLOT nor PREDICATE_NAME. Values are compared with the generator's
exactly (a zero's sign through atan2, since the runtime prints -0.0 as 0),
and each read must fall between x_c and x_{c+1}: `when is x` in the straight
form, the count of recorded assignments (`len of OUT`) in the loop form,
where interrogating x would take it out of its slot. A row's capability
(ieee, int64) is derived from its values (derive.py); a capability row runs
only when the probe shows the capability. ONE probe decides the ieee
capability and the numbers mode: `1e308 * 10` overflows to inf AND inf * 0
is NaN (a binary with one and not the other is mixed IEEE behaviour, exit
2). A skip warns, and an --expect'ed capability that is absent fails. The
reference model (reference.py, distance and the runtime's entropy signal,
#1667) shares the observer's window and tolerances, so it is correlated
with the runtime, not independent evidence.

Exit 1: a FINDING (any reading, REPORTED ones included, that differs
between arms), a wrong verdict on a capability row, an expected capability
absent, or (--floor) a floor verdict now wrong. --declared FILE (#1758, #1830:
Phase 2's tests/phase2/oracle_expect.txt, the shape of cost_expect.txt) lists
known-wrong CAPABILITY verdicts, one TSV row each: arm, row@checkpoint,
predicate, recover_round, reason. A declared wrong verdict does not fail; an
undeclared one does, and so does a STALE declaration, one whose verdict is
right now or was not examined, so a fix forces the declaration out. A row the
parser cannot read is a harness error. There are no waivers on the floor: a
floor verdict agrees with its label, so losing it is wrong unless the label
is, and a wrong label is fixed through derive/certify, which re-measures the
floor. The floor's anchor is the binary build_anchor.sh builds from tag
v0.46.0 into ${XDG_CACHE_HOME:-~/.cache}/eigs-oracle-anchor/<sha256 of the
recipe>/. Its identity is the recipe plus the verdict list, re-measured on
it every --floor run; the binary's sha256 is information only (another
toolchain builds other bytes). --write-floor refuses any binary but the one
the recipe stamped on this machine. Exit 2 on any harness error (a failing
program, a bad output line, a value off the generator, a run whose listing
does not show its arm's path, a VACUOUS run, stale certificates or labels, a
refused floor, an internal exception).
"""
import contextlib
from decimal import Decimal, InvalidOperation
import fcntl
import hashlib
import json
import math
import os
import re
import signal
import struct
import subprocess
import sys
import tempfile

import derive
import reference
from derive import CAPABILITIES as CAPS, PREDS
from gen import HarnessError, INT64_MIN, IN_PROGRAM, generate, program

ROW_TIMEOUT = 120
CLAMP = 1e308          # the default build saturates here (EIGS_NUM_MAX)
HERE = os.path.dirname(os.path.abspath(__file__))
TIERS = {"interp": {"EIGS_JIT_OFF": "1"}, "jit": {}, "osr": {"EIGS_JIT_OSR_THRESHOLD": "1"}}
ARMS = (("interp", "straight"), ("interp", "loop"), ("jit", "loop"), ("osr", "loop"))
WARMUP = {"interp": 0, "jit": 50, "osr": 0}       # src/jit.c: a function compiles at 50 calls
DUMP, HOT = {"EIGS_DUMP_BC": "1"}, {"EIGS_JIT_HOT": "1"}
GRADES = {"straight": ("OBSERVE_ASSIGN", "PREDICATE_NAME"),       # x's observe op, its read op
          "loop": ("OBSERVE_ASSIGN_LOCAL", "PREDICATE_SLOT")}
IEEE_PROBE = 'y is 1e308 * 10\nz is y * 0.0\nprint of f"{y} {z != z}"'
PROBES = {"ieee": IEEE_PROBE,
          "int64": "print of ((9223372036854775807 - 9223372036854775806) == 1)",  # 0 in doubles
          "int64_kind": "print of (num_type of 9223372036854775807)"}
FLOOR_FORMAT = "per-verdict/3"
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
                           f" first {diff[0]}; regenerate with derive.py --corpus <corpus> --write")
    return committed


# --- programs ---------------------------------------------------------------

def literal(v):
    """Round-trip spelling: an int row's integer literal (INT64_MIN as the
    Lua idiom in parentheses, since a lone 9223372036854775808 is a float
    under N1 and the literal is spliced into x * a + b), or a float literal
    with float(literal(v)) == v in every bit."""
    if isinstance(v, int):
        return "(-9223372036854775807 - 1)" if v == INT64_MIN else str(v)
    if not math.isfinite(v):
        raise HarnessError(f"non-finite literal {v!r}: inf and NaN must be computed in the program")
    return repr(v)


def steps(row, xs, upto):
    """x_0..x_upto as the runtime assigns them: a literal, or x * a + b."""
    if row["gen"]["kind"] in IN_PROGRAM:
        out = program(row["gen"], upto)
    else:
        out = [("set", v) for v in xs[:upto + 1]]
    # The non-capability floor measures the original binary64 observer.
    # Python ints in its corpus JSON are exact mathematical values, not a
    # request to change the measured execution tier after the int flip.
    if row.get("capability") != "int64":
        out = [(s[0], *(float(v) for v in s[1:])) for s in out]
    return out


def ck_line(at, ys, form):
    """The checkpoint read: the six predicates of x, then how many values
    were assigned before it: `when is x` (and y) in the straight form, where x
    is a module-level name anyway; in the loop form the count of recorded
    assignments, since interrogating x would take it out of its slot."""
    reads = " ".join("{" + read_expr(p) + "}" for p in PREDS)
    names = ("x", "y") if ys is not None else ("x",)
    counts = [f"{{when is {v}}}" if form == "straight" else f"{{len of {'OUT' if v == 'x' else 'OUTY'}}}"
              for v in names]
    return f'print of f"CK {at} {reads} {" ".join(counts)}"'


def is_zero(v):
    return isinstance(v, float) and v == 0.0


def sign_line(tag, i, spell):
    """For a value the generator holds as a zero: the runtime's sign bit of
    its i-th value (spelled `spell`), read through atan2, since the runtime
    prints -0.0 as 0."""
    return f'print of f"S {tag} {i} {{(atan2 of [{spell}, -1.0]) < 0.0}}"'


def emit_straight(row, xs, ys):
    """Every assignment is followed by a V (and Y) line carrying the runtime's
    value, and every checkpoint line by `when is x` (and y)."""
    out, cks = [], set(row["checkpoints"])
    for i, s in enumerate(steps(row, xs, row["n"])):
        out.append(f"x is {literal(s[1])}" if s[0] == "set"
                   else f"x is x * {literal(s[1])} + {literal(s[2])}")
        out.append(f'print of f"V {i} {{x}}"')
        out += [sign_line("V", i, "x")] if is_zero(xs[i]) else []
        if ys is not None:
            out += [f"y is {literal(ys[i])}", f'print of f"Y {i} {{y}}"']
            out += [sign_line("Y", i, "y")] if is_zero(ys[i]) else []
        if i in cks:
            out.append(ck_line(i, ys, "straight"))
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
    checkpoint c. x is never interrogated, so it lives in a slot. `warm`
    calls with m = 0 come first: they compile run_row without one back-edge
    or assignment, and each call has fresh locals, so the measured call's
    observer state is its own."""
    st = steps(row, xs, c)
    aff = [s for s in st if s[0] == "aff"]
    integer = row.get("capability") == "int64"
    zero, one = (0, 1) if integer else (0.0, 1.0)
    out = table("OPS", [zero if s[0] == "set" else one for s in st])
    out += table("A", [zero if s[0] == "set" else s[1] for s in st] if aff else [])
    out += table("B", [s[1] if s[0] == "set" else s[2] for s in st])
    out += table("YB", ys[:c + 1]) if ys is not None else []
    out += ["OUT is []", "OUTY is []", "define run_row(m) as:", f"    i is {literal(zero)}", "    if m > 0.0:",
            "        loop while true:", f"            if OPS[i] == {literal(zero)}:", "                x is B[i]",
            "            else:", "                x is x * A[i] + B[i]", "            append of [OUT, x]"]
    out += ["            y is YB[i]", "            append of [OUTY, y]"] if ys is not None else []
    out += [f"            i is i + {literal(one)}", "            if i >= m:", "                break",
            "        " + ck_line(c, ys, "loop"), "    return 0.0",
            f"for k in range of {warm}:", "    r is run_row of 0.0", f"r is run_row of {float(c + 1)!r}",
            "for k in range of (len of OUT):", '    print of f"V {k} {OUT[k]}"',
            "for k in range of (len of OUTY):", '    print of f"Y {k} {OUTY[k]}"']
    out += [sign_line("V", k, f"OUT[{k}]") for k in range(c + 1) if is_zero(xs[k])]
    out += [sign_line("Y", k, f"OUTY[{k}]") for k in range(c + 1) if ys is not None and is_zero(ys[k])]
    return "\n".join(out + [f'print of "ROW_DONE {row["id"]}"']) + "\n"


# --- running ----------------------------------------------------------------

def run_group(cmd, timeout, env=None, cwd=None):
    """subprocess.run in a session of its own: on a timeout, and after any
    exit, the whole process GROUP is killed, so no grandchild outlives the
    call (an orphan on a 4 GB box is a freeze). TimeoutExpired propagates."""
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, env=env, cwd=cwd, start_new_session=True)
    try:
        out, err = p.communicate(timeout=timeout)
    finally:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(p.pid, signal.SIGKILL)
        if p.returncode is None:
            p.communicate()
    return subprocess.CompletedProcess(cmd, p.returncode, out, err)


def scrubbed(own):
    """The inherited environment without any EIGS_* variable, plus the arm's own."""
    return {**{k: v for k, v in os.environ.items() if not k.startswith("EIGS_")}, **own}


def check_value(rid, tag, i, want, tok, neg):
    """The runtime's printed value against the generator's, exactly: an int
    row's ints, a NaN by NaN-ness (IEEE 754 leaves a NaN's sign open), a zero
    by its sign bit `neg` (the S line), anything else in every bit."""
    try:
        got = int(tok) if isinstance(want, int) and re.fullmatch(r"-?\d+", tok) else float(tok)
    except ValueError:
        raise HarnessError(f"{rid}: {tag}_{i} unparsable value {tok!r}")
    if isinstance(want, int):
        ok = float(got).is_integer() and int(got) == want
    elif want != want:
        ok = got != got
    elif want == 0.0:
        ok = got == 0.0 and neg == (math.copysign(1.0, want) < 0)
    else:
        ok = struct.pack("<d", got) == struct.pack("<d", want)
    if not ok:
        raise HarnessError(f"{rid}: {tag}_{i} runtime={tok}{'' if neg is None else f' (sign bit {neg})'}"
                           f" generator={want!r} (values must agree in every bit)")


def run(binary, prog, env):
    try:
        p = run_group([binary, prog], ROW_TIMEOUT, env=scrubbed(env))
    except (OSError, subprocess.TimeoutExpired) as e:
        raise HarnessError(f"{os.path.basename(prog)}: cannot run {binary}: {e}")
    hot = HOT_BLOCK.search(p.stderr)
    errors = [ln for ln in HOT_BLOCK.sub("", p.stderr).splitlines()
              if ln.strip() and not DIAG_LINE.match(ln)]
    return p.returncode, p.stdout.splitlines(), errors, p.stderr, hot.group(0) if hot else ""


def printed_count(token):
    """Parse a printed count by exact value, including N6's integral floats.

    Decimal avoids both truncating a fractional count and rounding large ints
    through binary64. Runtime values still use check_value's bitwise oracle.
    """
    try:
        value = Decimal(token)
        if value.is_finite() and value == value.to_integral_value():
            return int(value)
    except (InvalidOperation, ValueError, OverflowError):
        pass
    raise HarnessError(f"non-integral printed count {token!r}")


def parse_run(row, cks, form, rc, lines, errors, xs, ys):
    rid = row["id"]
    if rc != 0 or errors or not lines or lines[-1] != f"ROW_DONE {rid}":
        raise HarnessError(f"{rid}: program failed (rc={rc})\nstderr: {' | '.join(errors)[:400]}\n"
                           f"stdout tail: {lines[-3:]}")
    got, vals, last, signs = {}, {"V": {}, "Y": {}}, {"V": -1, "Y": -1}, {}
    for ln in lines[:-1]:
        f = ln.split()
        if len(f) == 3 and f[0] in vals:
            i = printed_count(f[1])
            if i != last[f[0]] + 1:
                raise HarnessError(f"{rid}: {f[0]} line {i} out of order after {last[f[0]]}")
            last[f[0]], vals[f[0]][i] = i, f[2]
            continue
        if len(f) == 4 and f[0] == "S" and f[1] in vals and f[3] in ("true", "false"):
            signs[(f[1], printed_count(f[2]))] = f[3] == "true"
            continue
        if len(f) != 9 + (ys is not None) or f[0] != "CK":
            raise HarnessError(f"{rid}: unexpected output line {ln!r}")
        at = printed_count(f[1])
        if at in got:
            raise HarnessError(f"{rid}: duplicate checkpoint {at}")
        if form == "straight" and (last["V"] != at or (ys is not None and last["Y"] != at)):
            raise HarnessError(f"{rid}: checkpoint {at} read after value {last['V']}:"
                               " a read must follow the assignment of x_at")
        if any(printed_count(w) != at + 1 for w in f[8:]):
            raise HarnessError(f"{rid}: checkpoint {at} read after {f[8:]} assignments,"
                               f" not {at + 1}: a read must fall between x_at and x_{at + 1}")
        if any(b not in ("true", "false") for b in f[2:8]):
            raise HarnessError(f"{rid}@{at}: non-boolean read {f[2:8]}")
        got[at] = dict(zip(PREDS, (b == "true" for b in f[2:8])))
    if sorted(got) != cks:
        raise HarnessError(f"{rid}: checkpoints read {sorted(got)}, expected {cks}")
    upto = row["n"] if form == "straight" else cks[-1]
    zeros = set()
    for tag, seq in (("V", xs), ("Y", ys)):
        if seq is None:
            continue
        if sorted(vals[tag]) != list(range(upto + 1)):
            raise HarnessError(f"{rid}: {len(vals[tag])} {tag} values read, expected {upto + 1}")
        for i in range(upto + 1):
            if is_zero(seq[i]):
                zeros.add((tag, i))
            check_value(rid, tag, i, seq[i], vals[tag][i], signs.get((tag, i)))
    if set(signs) != zeros:
        raise HarnessError(f"{rid}: sign lines for {sorted(signs)}, expected one per zero {sorted(zeros)}")
    return got


def grades(rid, tier, form, err, cks):
    """The opcode gate: the run's EIGS_DUMP_BC listing must show the path its
    arm grades. x is observed through GRADES[form][0] and every predicate is
    read through GRADES[form][1] on that same x: in run_row for the loop
    form (a slot), in the module chunk for the straight form (a name)."""
    asg_op, read_op = GRADES[form]
    name = "run_row" if form == "loop" else "<module>"
    sec = re.search(rf"^=== [^\n]*\({re.escape(name)}, [^\n]*\n((?:\d{{4,}} [^\n]*\n?)*)", err, re.M)
    ops = re.findall(r"^\d{4,} \[L\d+\] (\S+) *(\S*) *(\S*)", sec.group(1), re.M) if sec else []
    reads = [o for o in ops if o[0].startswith("PREDICATE")]
    target = {o[2] for o in reads}
    if not (len(reads) == len(PREDS) * len(cks) and {o[0] for o in reads} == {read_op} and len(target) == 1
            and any(o[0] == asg_op and o[1] in target for o in ops)):
        raise HarnessError(f"{rid}@{cks[-1]} {tier}/{form}: this arm grades x through {asg_op} and {read_op},"
                           f" but its EIGS_DUMP_BC listing of {name} reads {len(reads)} predicate(s) through"
                           f" {sorted({o[0] for o in reads})} and observes x through"
                           f" {sorted({o[0] for o in ops if o[0].startswith('OBSERVE_ASSIGN')})}")


def witness(tier, rid, err, hot, held, c, integer=False, int64=False):
    """("native" | "value bail" | "int refusal" | "VACUOUS", detail) for the measured call's
    loop. The thunk's last exit must lie past the loop's back-edge (the body
    ran to its `break` natively). jit: the function thunk, with bked = 0 (after
    a bail the rest of the call runs interpreted), so every iteration ran
    natively, x_0 included; `adv` RET means it ran through RETURN. osr: the
    OSR thunk's last exit covers the LAST iteration only; OSR compiles at the
    first back-edge, so x_0 runs interpreted, and an earlier iteration that
    bailed leaves no trace until #1768. A stop INSIDE the computation of x
    (from the body's MUL to the next OBSERVE_ASSIGN) on a non-finite or
    clamped value is the JIT's designed bail (#1758 N12)."""
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
        adv = hrow[4] if hrow[2] == "yes" else "-1"
        at = int(hrow[5]) if adv == "RET" else int(adv) if adv.isdigit() else -1
        ok, k = at > jb and bked == 0, c - bked       # x_k is the value whose iteration bailed
    else:
        head = jb + 3 - int(ops[jb][1])
        at = int(hrow[10]) + int(hrow[9]) if hrow[8] == "yes" and int(hrow[10]) == head else -1
        ok, k = at > jb, c
    stop = f"{ops[at][0]}@{at}" if at in ops else f"the end of run_row ({at})" if at >= 0 else "no thunk"
    if ok:
        return "native", f"exits at {stop}, past the back-edge at {jb}"
    # R1.3 through R5: exact int capability rows intentionally contain int
    # opcodes which both JIT scanners refuse by default. Keep all their
    # JIT-enabled verdicts scored, but name the actual interpreted tier.
    # A float row or an int opcode after x's assignment cannot claim this
    # witness. An OSR prefix may run the float indexing/control before the
    # refusal; its recorded exit must be AT the int opcode, before observing
    # x. Disabling the JIT globally still reds the native float rows.
    head = jb + 3 - int(ops[jb][1])
    observed = min((o for o, (op, _arg) in ops.items()
                    if o >= head and op.startswith("OBSERVE_ASSIGN")), default=head)
    intstops = {o: op for o, (op, _arg) in ops.items()
                if head <= o < observed and op in ("INT_ZERO", "INT_ONE", "INT_CONST")}
    osr_at = int(hrow[10]) + int(hrow[9]) if hrow[8] == "yes" and int(hrow[10]) == head else -1
    absent = tier == "jit" and hrow[8] in ("?", "no")
    function_absent = hrow[2] == "no" if tier == "jit" else hrow[2] in ("?", "no")
    refused = (absent and hrow[11] in intstops.values()) or osr_at in intstops
    if integer and int64 and intstops and function_absent and refused:
        detail = "no OSR thunk" if absent else f"OSR prefix exits at {intstops[osr_at]}@{osr_at}, before x's observe@{observed}"
        return "int refusal", f"x observed interpreted: no function thunk; {detail} (R5)"
    mul = min((o for o, (op, _a) in ops.items() if op == "MUL" and o < jb), default=jb)
    asg = min((o for o, (op, _a) in ops.items() if op.startswith("OBSERVE_ASSIGN") and o > mul), default=mul)
    bad = [v for v in held[max(0, k - 1):k + 1] if not math.isfinite(v) or abs(v) >= CLAMP]
    if bad and mul <= at <= asg:
        return "value bail", f"stops at {stop}, computing x, on x = {bad[-1]!r}"
    return "VACUOUS", f"stops at {stop} (bked={bked}), not on a non-finite value computing x"


def probe(binary, code):
    try:
        p = run_group([binary, "-e", code], 30, env=scrubbed({}))
    except (OSError, subprocess.TimeoutExpired) as e:
        raise HarnessError(f"cannot probe {binary}: {e}")
    return p.stdout.strip()


def capabilities(binary, asked):
    """(ieee numbers?, {capability: present}, probe outputs). ONE probe decides
    the ieee capability and the numbers mode: `1e308 * 10` is inf AND inf * 0
    is NaN, what the ieee rows need; the clamp build gives 1e+308 and no NaN."""
    out = {k: probe(binary, c) for k, c in PROBES.items()}
    seen = {"inf true": (True, True), "1e+308 false": (False, False),
            "inf false": (True, False), "1e+308 true": (False, True)}.get(out["ieee"])
    if seen is None:
        raise HarnessError(f"IEEE probe {IEEE_PROBE!r} printed {out['ieee']!r}, not 'inf true' (IEEE)"
                           " or '1e+308 false' (the clamp)")
    if seen[0] != seen[1]:
        raise HarnessError(f"mixed IEEE behaviour: the IEEE probe printed {out['ieee']!r}: 1e308 * 10"
                           f" {'overflows to inf' if seen[0] else 'clamps to 1e308'} but inf * 0"
                           f" {'is' if seen[1] else 'is not'} NaN. The ieee rows need both and the clamp"
                           " rows neither: this binary is neither instrument")
    mode = "ieee" if seen[0] else "clamp"
    if asked and asked != mode:
        raise HarnessError(f"--numbers {asked} contradicts the binary: the probe printed {out['ieee']!r}")
    caps = {"ieee": seen[0], "int64": out["int64"] == "true" and out["int64_kind"] == "int"}
    return mode == "ieee", caps, out


def measure(binary, corpus, caps):
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
            res["held"][rid] = xs          # the values the runtime holds, exactly (ints stay ints)
            jobs = [("interp", "straight", row["checkpoints"], emit_straight(row, xs, ys))]
            jobs += [(t, "loop", [c], emit_loop(row, xs, ys, c, WARMUP[t]))
                     for c in row["checkpoints"] for t in TIERS]
            for tier, form, cks, text in jobs:
                prog = os.path.join(tmp, f"{rid}@{cks[-1]}.{tier}.{form}.eigs")
                with open(prog, "w") as f:
                    f.write(text)
                rc, lines, errors, err, hot = run(binary, prog, {**TIERS[tier], **DUMP,
                                                                 **(HOT if tier != "interp" else {})})
                got = parse_run(row, cks, form, rc, lines, errors, xs, ys)
                grades(rid, tier, form, err, cks)
                res["runs"] += 1
                if tier != "interp":
                    res["wit"][(tier, rid, cks[0])] = witness(
                        tier, rid, err, hot, xs, cks[0],
                        integer=row.get("capability") == "int64", int64=caps["int64"])
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


def load_declared(path, rows):
    """--declared FILE -> {(arm, row, checkpoint, predicate): (recover_round, reason)}.
    Only capability verdicts can be declared; anything unreadable is refused."""
    arms, out = {f"{t}/{f}" for t, f in ARMS}, {}
    with open(path) as f:
        lines = f.read().splitlines()
    for n, line in enumerate(lines, 1):
        if not line.strip():
            continue
        fields = [x.strip() for x in line.split("\t")]
        if len(fields) != 5:
            raise HarnessError(f"{path}:{n}: expected five TSV fields"
                               " (arm, row@checkpoint, predicate, recover_round, reason)")
        arm, rc, p, rnd, why = fields
        rid, _, at = rc.partition("@")
        row = rows.get(rid)
        if (arm not in arms or not row or not row.get("capability") or not at.isdigit()
                or int(at) not in row["checkpoints"] or p not in PREDS):
            raise HarnessError(f"{path}:{n}: not a capability verdict: {arm} {rc} {p}")
        if not re.fullmatch(r"R[1-9][0-9]*(?:\.[1-9][0-9]*)?", rnd) or not why:
            raise HarnessError(f"{path}:{n}: recover_round (a round name) and reason are required")
        if (arm, rid, int(at), p) in out:
            raise HarnessError(f"{path}:{n}: duplicate declaration {arm} {rc} {p}")
        out[(arm, rid, int(at), p)] = (rnd, why)
    return out


def findings(res):
    """Every (row, checkpoint, predicate) whose readings differ between arms,
    REPORTED readings included: a split is a fault whatever the label."""
    reads = {}
    for (tier, form, rid, at, p), got in res["read"].items():
        reads.setdefault((rid, at, p), {})[f"{tier}/{form}"] = got
    return [(k, r) for k, r in reads.items() if len(set(r.values())) > 1]


def right_set(v, rows):
    """The runtime verdicts the binary got right on rows with no capability,
    keyed as floor.json keys them."""
    return sorted(f"{arm} {rid}@{at} {p} {cls}" for (arm, rid, at, p), (cls, want, got) in v.items()
                  if "/" in arm and want == got and not rows[rid].get("capability"))


def anchor_dir():
    root = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(root, "eigs-oracle-anchor", sha256(RECIPE))


def anchor():
    """The stamp build_anchor.sh wrote beside the binary it built from the
    recipe as it stands (the directory is named by the recipe's sha256),
    checked against the binary as it is."""
    d = anchor_dir()
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


@contextlib.contextmanager
def anchor_lock():
    """build_anchor.sh rebuilds under the exclusive lock; measuring holds it shared."""
    with open(anchor_dir() + ".lock", "a") as f:
        fcntl.flock(f, fcntl.LOCK_SH)
        yield


def floor_preflight(path):
    """Everything --floor can refuse before measuring anything: no waivers,
    the format, the recipe the floor was measured by, the local anchor."""
    if os.path.exists(os.path.join(os.path.dirname(os.path.abspath(path)), "waivers.json")):
        raise HarnessError("waivers.json: waivers are removed by design. A floor verdict agrees with its"
                           " label, so an observer that loses it is wrong unless the label is; fix a wrong"
                           " label through derive.py/certify.py, which re-measures the floor")
    try:
        with open(path) as f:
            floor = json.load(f)
    except (OSError, ValueError) as e:
        raise HarnessError(f"cannot load the floor {path}: {e}")
    if floor.get("format") != FLOOR_FORMAT or not isinstance(floor.get("verdicts"), list):
        raise HarnessError(f"floor {path}: not a {FLOOR_FORMAT} floor")
    if floor.get("anchor", {}).get("recipe_sha256") != sha256(RECIPE):
        raise HarnessError(f"floor {path} was measured on the anchor of another recipe"
                           f" ({floor.get('anchor', {}).get('recipe_sha256')}); build_anchor.sh is now"
                           f" {sha256(RECIPE)}: build its anchor and re-measure with --write-floor")
    return floor, anchor()


def check_floor(pre, path, cand_v, rows, corpus, labels):
    """1 when a floor verdict is now wrong, 0 otherwise; HarnessError when the
    floor is not the measurement of the recipe's anchor on this machine NOW
    (its identity: the recipe plus the verdict list; the binary's sha256 is
    information only, since another toolchain builds other bytes)."""
    floor, stamp = pre
    with anchor_lock():
        ieee, caps, _ = capabilities(stamp["binary"], None)
        want = right_set(verdicts(measure(stamp["binary"], corpus, caps), corpus, labels), rows)
    extra, missing = sorted(set(floor["verdicts"]) - set(want)), sorted(set(want) - set(floor["verdicts"]))
    if extra or missing or len(floor["verdicts"]) != len(want):
        built = stamp.get("toolchain") or "an unrecorded toolchain"
        measured = floor["anchor"].get("toolchain") or "an unrecorded toolchain"
        cause = (f"This anchor was built by {built!r}, and the floor was measured on a build by {measured!r}: a"
                 " toolchain or image change (in CI, a new dev-image digest) is the likely cause" if built != measured
                 else f"This anchor was built by the floor's own toolchain ({built!r}), so the toolchain is not the cause")
        raise HarnessError(f"floor {path} is not its anchor's measurement: {len(extra)} listed verdict(s)"
                           f" the anchor gets wrong (first {extra[:1]}), {len(missing)} right one(s) missing"
                           f" (first {missing[:1]}). {cause}. Re-measure the floor where the check runs, in the"
                           f" CI image: make observer-anchor, then score.py {stamp['binary']} --write-floor {path}")
    same = floor["anchor"].get("binary_sha256") == stamp["binary_sha256"]
    print(f"\nfloor: {len(want)} verdicts ({FLOOR_FORMAT}), re-measured on the anchor {stamp['binary']}"
          f" built by build_anchor.sh {stamp['recipe_sha256'][:12]}: the list matches; binary sha256"
          f" {stamp['binary_sha256'][:12]} " + ("as when the floor was measured" if same else
                                               f"differs from the floor's {floor['anchor'].get('binary_sha256', '?')[:12]}"
                                               " (another toolchain: information only)"))
    cand = {f"{arm} {rid}@{at} {p} {cls}": w == g for (arm, rid, at, p), (cls, w, g) in cand_v.items() if "/" in arm}
    judged = {k: cand[k] for k in floor["verdicts"]}      # the count printed is the verdicts compared (#1777)
    lost = [k for k, right in judged.items() if not right]
    for k in lost:
        print(f"  FLOOR VIOLATION {k}")
    print(f"floor: {len(judged)} verdicts checked, {len(lost)} lost")
    return 1 if lost else 0


def report(v, res, corpus, numbers, caps, probes, labels, reported, expect):
    arms = [f"{t}/{f}" for t, f in ARMS] + ["REFERENCE", "REFERENCE_ENTROPY"]
    scored = derive.scored_classes(corpus)[0]
    print(f"observer oracle: {len(corpus['rows'])} rows, {len(res['held'])} run, {len(res['skipped'])} skipped"
          f" by capability; {res['runs']} programs; numbers={numbers}")
    for cap in CAPS:
        n = sum(1 for _r, c in res["skipped"] if c == cap)
        line = f"capability {cap}: probe printed {probes[cap]!r}" + (
            f", num_type {probes['int64_kind']!r}" if cap == "int64" else "") + ": "
        if caps[cap]:
            print(f"  {line}present, {sum(1 for r in corpus['rows'] if r.get('capability') == cap)} row(s) run")
        else:
            print(f"  {'EXPECTED ' if cap in expect else 'WARNING: '}{line}ABSENT, {n} row(s) SKIPPED")
    print(f"PATHS, checked in each of the {res['runs']} programs' EIGS_DUMP_BC listing: "
          + "; ".join(f"the {form} form observes x through {a} and reads it through {r}" for form, (a, r) in GRADES.items()))
    print("\nTIER WITNESS, per run (n native, v interpreted: a value bail on a non-finite or clamped value,"
          " i interpreted int opcode refusal until R5, V VACUOUS;"
          " jit: every iteration, x_0 included; osr: the last iteration only, #1768):")
    for row in corpus["rows"]:
        if row["id"] in res["held"]:
            print(f"  {row['id']:22}" + " ".join(
                f"@{c} jit:{res['wit'][('jit', row['id'], c)][0][0]} osr:{res['wit'][('osr', row['id'], c)][0][0]}"
                for c in row["checkpoints"]))
    for t in ("jit", "osr"):
        w = {k[1:]: x for k, x in res["wit"].items() if k[0] == t}
        print(f"  {t}: {sum(1 for x in w.values() if x[0] == 'native')} of {len(w)} runs witness a native body;"
              f" minimum: every run except a value bail or witnessed int opcode refusal, and at least one")
        for (rid, c), (status, detail) in w.items():
            if status != "native":
                print(f"    {status.upper() if status == 'VACUOUS' else 'interpreted (' + status + ')'} {t}"
                      f" {rid}@{c}: {detail}")
    print("  predicate reads run interpreted in every tier: the JIT compiles neither PREDICATE_SLOT nor PREDICATE_NAME")
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
    print("\nDOCUMENTATION TABLE, per-predicate right/total (derived; incumbent is interp/straight)")
    print("  predicate        incumbent       REFERENCE REFERENCE_ENTROPY   constant-false")
    for p in PREDS:
        cells = []
        for a in ("interp/straight", "REFERENCE", "REFERENCE_ENTROPY"):
            judged = [x for k, x in v.items() if k[0] == a and k[3] == p]
            cells.append(f"{sum(x[1] == x[2] for x in judged)}/{len(judged)}")
        labelled = [x for k, x in v.items() if k[0] == "interp/straight" and k[3] == p]
        false_score = sum(not x[1] for x in labelled)
        print(f"  {p:12}{cells[0]:>13}{cells[1]:>16}{cells[2]:>18}"
              f"{false_score:>10}/{len(labelled)}")
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
    for flag in ("--corpus", "--numbers", "--expect", "--floor", "--declared", "--write-floor", "--note"):
        if flag in args:
            i = args.index(flag)
            if i + 1 >= len(args):
                raise HarnessError(f"{flag} needs a value")
            opts[flag] = args[i + 1]
            del args[i:i + 2]
    expect = set(filter(None, opts.get("--expect", "").split(",")))
    if len(args) != 1 or opts.get("--numbers", "clamp") not in ("ieee", "clamp") or expect - set(CAPS):
        raise HarnessError("usage: score.py BINARY [--corpus PATH] [--numbers ieee|clamp] [--expect ieee,int64]"
                           " [--floor FILE] [--declared FILE] [--write-floor FILE [--note TEXT]]")
    binary = os.path.abspath(args[0])
    if not (os.path.isfile(binary) and os.access(binary, os.X_OK)):
        raise HarnessError(f"binary not found or not executable: {binary}")
    stamp = anchor() if "--write-floor" in opts else None
    if stamp and os.path.realpath(binary) != os.path.realpath(stamp["binary"]):
        raise HarnessError(f"--write-floor measures only the anchor build_anchor.sh builds"
                           f" ({stamp['binary']}), not {binary}")
    corpus_path = opts.get("--corpus", os.path.join(HERE, "corpus.json"))
    cdir = os.path.dirname(os.path.abspath(corpus_path))
    corpus = derive.load_corpus(corpus_path)
    certs = derive.load_certificates(corpus, os.path.join(cdir, "certificate.json"))
    labels = load_labels(corpus, certs, os.path.join(cdir, "labels.json"))
    pre = floor_preflight(opts["--floor"]) if "--floor" in opts else None
    rows = {r["id"]: r for r in corpus["rows"]}
    declared = load_declared(opts["--declared"], rows) if "--declared" in opts else None
    ieee, caps, probes = capabilities(binary, opts.get("--numbers"))
    with anchor_lock() if stamp else contextlib.nullcontext():
        res = measure(binary, corpus, caps)
    v = verdicts(res, corpus, labels)
    report(v, res, corpus, "ieee" if ieee else "clamp", caps, probes, labels,
           derive.scored_classes(corpus)[1], expect)
    vacuous = [f"{t} {rid}@{c}: {d}" for (t, rid, c), (s, d) in res["wit"].items() if s == "VACUOUS"]
    if vacuous or not all(any(k[0] == t and x[0] == "native" for k, x in res["wit"].items()) for t in ("jit", "osr")):
        raise HarnessError(f"VACUOUS: {len(vacuous)} JIT-tier run(s) did not run their loop body natively"
                           f" and stopped on finite values, first {vacuous[:1]}; or a tier witnessed no run")
    split = findings(res)
    print(f"\nFINDINGS (a reading, REPORTED ones included, that differs between arms; each one fails the run):"
          f" {len(split)}")
    for (rid, at, p), r in split:
        print(f"  FINDING {rid}@{at} {p}: " + " ".join(f"{a}={str(b).lower()}" for a, b in r.items()))
    capwrong = [k for k, (cls, want, got) in v.items() if "/" in k[0] and rows[k[1]].get("capability") and want != got]
    ran = sorted({k[1] for k in v if rows[k[1]].get("capability")})
    missing = sorted(c for c in expect if not caps[c])
    print(f"\nCAPABILITY ROWS (every scored verdict must be right): {len(ran)} run, {len(res['skipped'])} skipped,"
          f" {len(capwrong)} wrong verdict(s); expected and absent: {missing or 'none'}")
    stale = []
    if declared is not None:
        stale = sorted(k for k in declared if k not in capwrong)
        print(f"DECLARED (--declared {opts['--declared']}): {len(declared)} declaration(s),"
              f" {sum(1 for k in capwrong if k in declared)} wrong as declared,"
              f" {sum(1 for k in capwrong if k not in declared)} undeclared wrong, {len(stale)} stale")
        for k in sorted(k for k in capwrong if k in declared):
            print(f"  DECLARED WRONG {k[0]} {k[1]}@{k[2]} {k[3]}: expected={str(v[k][1]).lower()}"
                  f" recover_round={declared[k][0]} reason={declared[k][1]}")
        for k in stale:
            print(f"  STALE DECLARATION {k[0]} {k[1]}@{k[2]} {k[3]}: "
                  + ("the verdict is right now; remove the declaration" if k in v else "not examined"))
        capwrong = [k for k in capwrong if k not in declared]
    for arm, rid, at, p in capwrong:
        print(f"  CAPABILITY WRONG {arm} {rid}@{at} {p}: expected={str(v[(arm, rid, at, p)][1]).lower()}")
    fail = 1 if split or capwrong or stale or missing else 0
    if pre:
        fail |= check_floor(pre, opts["--floor"], v, rows, corpus, labels)
    if stamp:
        with open(opts["--write-floor"], "w") as f:
            json.dump({"format": FLOOR_FORMAT, "note": opts.get("--note", ""), "numbers": "ieee" if ieee else "clamp",
                       "anchor": {k: stamp.get(k) for k in ("tag", "commit", "recipe_sha256", "binary_sha256",
                                                            "toolchain")},
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
