#!/usr/bin/env python3
"""Score EigenScript's observer against a ground-truth corpus (#1746, #1758).

usage: score.py BINARY [--corpus PATH] [--numbers ieee|clamp]
                       [--floor FILE] [--write-floor FILE [--note TEXT]]

Labels come from labels.json, which must equal derive.py's derivation from
the certified corpus (the label gate). For each corpus row this generates
the sequence in Python and runs it on BINARY in two FORMS: straight-line
code, and a loop form (a function iterating the row's values from a list
literal, or the affine recurrence itself) that the JIT can compile. Each
form runs in three TIERS: interp (EIGS_JIT_OFF=1), jit (the default JIT,
after enough warm-up calls to compile the function) and osr
(EIGS_JIT_OSR_THRESHOLD=1); in the jit and osr tiers EIGS_JIT_STATS must
report compiled > 0 for the loop form, or the run FAILS as vacuous. All six
predicates are read with the PER-VARIABLE form (`converged of x`); row
`two_vars` catches a harness that uses bare predicates. Every value the
runtime holds is compared exactly with the generator's (bit-exact floats;
int rows exactly, printed as `3` or `3.0`), and every checkpoint read must
fall after the assignment of its value and before the next one (`when is x`
counts the binding's assignments). --numbers (default: probe the binary
with `print of (1e308 * 10)`) selects whether an overflowing generator value
must come back as IEEE inf/NaN or as the +-1e308 clamp; the reference arms
see the values the runtime held.

MATH verdicts are the headline score; CONVENTION verdicts are scored in their
own tables; EIGS-DEFINED verdicts are listed. The reference model
(reference.py) is scored on the distance signal and on the runtime's entropy
signal (#1667); it implements the DEFINITIONS independently but at the
observer's window and tolerances, so its agreement with the runtime on
window-limited rows is correlated, not independent evidence. A predicate
reading that differs between tiers or forms is printed as a FINDING.

--floor FILE exits 1 when any runtime per-predicate TP or TN (MATH and
CONVENTION, every tier and form) is below the floor's, and refuses (exit 2)
a floor measured on another corpus or labels. --write-floor records this
run's counts as a floor. Without --floor the run is a report: exit 0
whatever the agreement. Exit 2 on any harness error (missing binary, a
program that errors, a missing, duplicate or misordered output line, a value
that differs from the generator, a vacuous JIT tier, a label that differs
from the derivation, a stale certificate or floor, an internal exception).
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
from derive import HarnessError, PREDS, generate

SCORED = ("MATH", "CONVENTION")
ROW_TIMEOUT = 120
CLAMP = 1e308          # the default build saturates here (EIGS_NUM_MAX)
HERE = os.path.dirname(os.path.abspath(__file__))
TIERS = (("interp", {"EIGS_JIT_OFF": "1"}), ("jit", {}), ("osr", {"EIGS_JIT_OSR_THRESHOLD": "1"}))
FORMS = ("straight", "loop")
JIT_STATS = re.compile(r"\[jit\] scanned=(\d+) compiled=(\d+)")


def read_expr(pred):
    """The one place a predicate read is spelled (per-variable form)."""
    return f"{pred} of x"


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


# --- labels -----------------------------------------------------------------

def load_labels(corpus, certs, path):
    """The label gate: labels.json must equal derive(corpus). derive() also
    asserts its own postconditions (the converged => stable lattice, and
    where EIGS-DEFINED may appear), so a derivation fault is caught there
    even when labels.json was regenerated from it."""
    try:
        with open(path) as f:
            committed = json.load(f)
    except (OSError, ValueError) as e:
        raise HarnessError(f"cannot load labels {path}: {e}")
    derived = derive.derive(corpus, certs)
    diff = sorted(k for k in set(committed) | set(derived)
                  if committed.get(k) != derived.get(k))
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
        return "-9223372036854775807 - 1" if v == derive.INT64_MIN else str(v)
    if not math.isfinite(v):
        raise HarnessError(f"non-finite literal {v!r}: only affine rows may overflow")
    return repr(v)


def _ck(i, ys):
    reads = " ".join("{" + read_expr(p) + "}" for p in PREDS)
    whens = " {when is x}" + (" {when is y}" if ys is not None else "")
    return f'print of f"CK {i} {reads}{whens}"'


def emit(row, xs, ys):
    """Straight-line form. Affine rows are emitted as the recurrence itself,
    so overflow happens in the runtime's own arithmetic; every other row
    assigns literals. Every assignment is followed by a V (and Y) line
    carrying the runtime's value, and every checkpoint line carries
    `when is x` (and y), which pins the read between x_at and x_{at+1}."""
    gen = row["gen"]
    cks = set(row["checkpoints"])
    out = []
    for i, v in enumerate(xs):
        if gen["kind"] == "affine" and i > 0:
            out.append(f"x is x * {literal(gen['a'])} + {literal(gen['b'])}")
        else:
            out.append(f"x is {literal(v)}")
        out.append(f'print of f"V {i} {{x}}"')
        if ys is not None:
            out.append(f"y is {literal(ys[i])}")
            out.append(f'print of f"Y {i} {{y}}"')
        if i in cks:
            out.append(_ck(i, ys))
    out.append(f'print of "ROW_DONE {row["id"]}"')
    return "\n".join(out) + "\n"


def emit_loop(row, xs, ys, warm):
    """Loop form: run_row iterates the row in a function the JIT can compile;
    `warm` silent calls come first (fresh locals each call, so the reported
    call's observer state is its own)."""
    gen, aff = row["gen"], row["gen"]["kind"] == "affine"
    out = []
    for name, seq in (("VALS", None if aff else xs), ("YVALS", ys)):
        for c in range(0, len(seq) if seq is not None else 0, 1000):   # list literals hold <= 1024
            lit = "[" + ", ".join(literal(v) for v in seq[c:c + 1000]) + "]"
            out += [f"{name} is {lit}"] if c == 0 else [f"for v in {lit}:", f"    append of [{name}, v]"]
    out.append("define run_row(loud) as:")
    body, ind = [], "    "
    if aff:
        out += [f"    x is {literal(gen['x0'])}", "    if loud == 1:", '        print of f"V 0 {x}"']
        if ys is not None:
            out += ["    y is YVALS[0]", "    if loud == 1:", '        print of f"Y 0 {y}"']
        out.append(f"    for j in range of {len(xs) - 1}:")
        body += ["i is j + 1", f"x is x * {literal(gen['a'])} + {literal(gen['b'])}"]
    else:
        out.append(f"    for i in range of {len(xs)}:")
        body.append("x is VALS[i]")
    body += ["if loud == 1:", '    print of f"V {i} {x}"']
    if ys is not None:
        body += ["y is YVALS[i]", "if loud == 1:", '    print of f"Y {i} {y}"']
    for c in row["checkpoints"]:
        body += [f"if loud == 1 and i == {c}:", "    " + _ck(c, ys)]
    out += [ind * 2 + line for line in body]
    out += ["    return 0", f"for k in range of {warm}:", "    r is run_row of 0",
            "r is run_row of 1", f'print of "ROW_DONE {row["id"]}"']
    return "\n".join(out) + "\n"


def warmups(tier, row):
    """The default JIT compiles a function after 50 calls, or at the next
    call once its loops ran 500 back-edges (src/jit.c thresholds)."""
    return min(50, -(-500 // (row["n"] + 1))) + 1 if tier == "jit" else 0


# --- running ----------------------------------------------------------------

def bits(v):
    return struct.pack("<d", v)


def check_value(rid, tag, i, want, tok, ieee):
    try:
        got = int(tok) if re.fullmatch(r"-?\d+", tok) else float(tok)
    except ValueError:
        raise HarnessError(f"{rid}: {tag}_{i} unparsable value {tok!r}")
    if isinstance(want, int):
        if not (float(got).is_integer() and int(got) == want):
            raise HarnessError(f"{rid}: {tag}_{i} runtime={tok} generator={want} (ints must agree exactly)")
    elif math.isfinite(want):
        if bits(float(got)) != bits(want):
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
    errs = [ln for ln in p.stderr.splitlines() if not JIT_STATS.match(ln)]
    stats = [tuple(map(int, m.groups())) for m in JIT_STATS.finditer(p.stderr)]
    return p.returncode, p.stdout.splitlines(), errs, stats


def parse_run(row, rc, lines, errs, xs, ys, ieee):
    rid = row["id"]
    if rc != 0 or errs or not lines or lines[-1] != f"ROW_DONE {rid}":
        raise HarnessError(f"{rid}: program failed (rc={rc})\nstderr: {' | '.join(errs)[:400]}\n"
                           f"stdout tail: {lines[-3:]}")
    got, vals = {}, {"V": {}, "Y": {}}
    last = {"V": -1, "Y": -1}                  # the program's own order
    for ln in lines[:-1]:
        f = ln.split()
        if len(f) == 3 and f[0] in vals:
            i = int(f[1])
            if i != last[f[0]] + 1:
                raise HarnessError(f"{rid}: {f[0]} line {i} out of order after {last[f[0]]}")
            last[f[0]] = i
            vals[f[0]][i] = f[2]
            continue
        if len(f) != 9 + (ys is not None) or f[0] != "CK":
            raise HarnessError(f"{rid}: unexpected output line {ln!r}")
        at = int(f[1])
        if at in got:
            raise HarnessError(f"{rid}: duplicate checkpoint {at}")
        if last["V"] != at or (ys is not None and last["Y"] != at):
            raise HarnessError(f"{rid}: checkpoint {at} read after value {last['V']}:"
                               " a read must follow the assignment of x_at")
        if any(w != str(at + 1) for w in f[8:]):
            raise HarnessError(f"{rid}: checkpoint {at} read after {f[8:]} assignments,"
                               f" not {at + 1}: a read must fall between x_at and x_{at + 1}")
        if any(b not in ("true", "false") for b in f[2:8]):
            raise HarnessError(f"{rid}@{at}: non-boolean read {f[2:8]}")
        got[at] = dict(zip(PREDS, (b == "true" for b in f[2:8])))
    if sorted(got) != row["checkpoints"]:
        raise HarnessError(f"{rid}: checkpoints read {sorted(got)}, expected {row['checkpoints']}")
    for tag, seq in (("V", xs), ("Y", ys)):
        if seq is None:
            continue
        if sorted(vals[tag]) != list(range(len(seq))):
            raise HarnessError(f"{rid}: {len(vals[tag])} {tag} values read,"
                               f" generator has {len(seq)}")
        for i, w in enumerate(seq):
            check_value(rid, tag, i, w, vals[tag][i], ieee)
    return got


def probe_numbers(binary, asked):
    try:
        out = subprocess.run([binary, "-e", "print of (1e308 * 10)"], capture_output=True,
                             text=True, timeout=30).stdout.strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        raise HarnessError(f"cannot probe {binary}: {e}")
    mode = {"inf": "ieee", "1e+308": "clamp"}.get(out)
    if mode is None:
        raise HarnessError(f"number probe `print of (1e308 * 10)` printed {out!r}, not inf or 1e+308")
    if asked and asked != mode:
        raise HarnessError(f"--numbers {asked} contradicts the binary: the probe printed {out!r}")
    return mode


# --- scoring ----------------------------------------------------------------

class Arm:
    def __init__(self, name):
        self.name = name
        self.conf = {c: {p: [0, 0, 0, 0] for p in PREDS} for c in SCORED}
        self.disagree = {c: [] for c in SCORED}
        self.eigs = []

    def add(self, rid, at, pred, ents, actual):
        if ents[0][0] == "EIGS-DEFINED":
            self.eigs.append((rid, at, pred, actual))
            return
        for cls, want, cite, why in ents:
            idx = {(True, True): 0, (False, True): 1, (True, False): 2,
                   (False, False): 3}[(want, actual)]
            self.conf[cls][pred][idx] += 1
            if want != actual:
                self.disagree[cls].append((rid, at, pred, want, actual, cite, why))

    def totals(self, cls):
        m = sum(sum(c) for c in self.conf[cls].values())
        a = sum(c[0] + c[3] for c in self.conf[cls].values())
        return m, a, m - a


def main(argv):
    args = argv[1:]
    opts = {}
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
    shas = {"corpus_sha256": sha256(corpus_path), "labels_sha256": sha256(os.path.join(cdir, "labels.json"))}
    floor = None
    if "--floor" in opts:
        try:
            with open(opts["--floor"]) as f:
                floor = json.load(f)
        except (OSError, ValueError) as e:
            raise HarnessError(f"cannot load floor {opts['--floor']}: {e}")
        for k, v in shas.items():
            if floor.get(k) != v:
                raise HarnessError(f"stale floor: its {k} is {floor.get(k)}, the current one is {v};"
                                   " re-measure it on the reference binary")
    ieee = probe_numbers(binary, opts.get("--numbers")) == "ieee"
    rows = corpus["rows"]
    declared = {c: sum(1 for v in labels.values() for ents in v.values()
                       for e in ents if e[0] == c) for c in SCORED}
    arms = {(t, f): Arm(f"RUNTIME[{t}/{f}]") for t, _ in TIERS for f in FORMS}
    refs = [Arm("REFERENCE"), Arm("REFERENCE_ENTROPY")]
    readings, compiled, examined = {}, {}, 0
    with tempfile.TemporaryDirectory(prefix="obs_oracle_") as tmp:
        for row in rows:
            xs = generate(row["gen"], row["n"])
            ys = generate(row["second"], row["n"]) if "second" in row else None
            for tier, env in TIERS:
                for form in FORMS:
                    prog = os.path.join(tmp, f"{row['id']}.{tier}.{form}.eigs")
                    with open(prog, "w") as f:
                        f.write(emit(row, xs, ys) if form == "straight"
                                else emit_loop(row, xs, ys, warmups(tier, row)))
                    rc, lines, errs, stats = run(binary, prog, {**env, "EIGS_JIT_STATS": "1"} if tier != "interp" else env)
                    got = parse_run(row, rc, lines, errs, xs, ys, ieee)
                    if form == "loop" and tier != "interp":
                        if not stats or stats[-1][1] == 0:
                            raise HarnessError(f"{row['id']}: vacuous {tier} tier: EIGS_JIT_STATS"
                                               f" reports {stats or 'nothing'}, so nothing was compiled")
                        compiled[(tier, row["id"])] = stats[-1][1]
                    for at in row["checkpoints"]:
                        for p in PREDS:
                            arms[(tier, form)].add(row["id"], at, p, labels[f"{row['id']}@{at}"][p], got[at][p])
                            readings.setdefault((row["id"], at, p), {})[(tier, form)] = got[at][p]
            # The reference arms see the values the RUNTIME held: the clamp, or IEEE inf/NaN.
            held = [float(x) if ieee or math.isnan(x) else max(-CLAMP, min(CLAMP, float(x))) for x in xs]
            hs = reference.entropy_signal(held)
            for at in row["checkpoints"]:
                v = labels[f"{row['id']}@{at}"]
                ref, ref_h = reference.classify(held, at), reference.classify(hs, at)
                for p in PREDS:
                    refs[0].add(row["id"], at, p, v[p], ref[p])
                    refs[1].add(row["id"], at, p, v[p], ref_h[p])
            examined += 1
    if examined != len(rows) or examined == 0:
        raise HarnessError(f"examined {examined} rows of {len(rows)}")
    for arm in list(arms.values()) + refs:
        for c in SCORED:
            if arm.totals(c)[0] != declared[c]:
                raise HarnessError(f"{arm.name} scored {arm.totals(c)[0]} {c}"
                                   f" verdicts, corpus declares {declared[c]}")
    measured = {t: {f: {c: {p: {"TP": arms[(t, f)].conf[c][p][0], "TN": arms[(t, f)].conf[c][p][3]}
                            for p in PREDS} for c in SCORED} for f in FORMS} for t, _ in TIERS}
    report(arms, refs, readings, compiled, examined, "ieee" if ieee else "clamp")
    if "--write-floor" in opts:
        with open(opts["--write-floor"], "w") as f:
            json.dump({**shas, "binary": {"path": binary, "sha256": sha256(binary)},
                       "note": opts.get("--note", ""), "numbers": "ieee" if ieee else "clamp",
                       "floors": measured}, f, indent=1)
            f.write("\n")
        print(f"floor written: {opts['--write-floor']}")
    if floor is not None:
        return check_floor(floor, measured)
    return 0


def check_floor(floor, measured):
    want = floor.get("floors")
    keys = lambda d: {(t, f, c, p, k) for t in d for f in d[t] for c in d[t][f]
                      for p in d[t][f][c] for k in d[t][f][c][p]}
    if not isinstance(want, dict) or keys(want) != keys(measured):
        raise HarnessError("stale floor: its tiers/forms/predicates differ from this run's")
    bad = [(t, f, c, p, k, measured[t][f][c][p][k], want[t][f][c][p][k])
           for (t, f, c, p, k) in sorted(keys(want))
           if measured[t][f][c][p][k] < want[t][f][c][p][k]]
    for t, f, c, p, k, got, fl in bad:
        print(f"FLOOR VIOLATION {t}/{f} {c} {p} {k}: {got} < floor {fl}")
    print(f"floor: {len(keys(want))} per-predicate counts checked, {len(bad)} below the floor")
    return 1 if bad else 0


def table(title, arms, cls):
    print(f"\n{title}: {cls} verdicts, per-predicate TP FP FN TN, agree/total")
    print(f"  {'predicate':12}" + "".join(f"{a.name:>28}" for a in arms))
    for p in PREDS:
        cells = []
        for a in arms:
            tp, fp, fn, tn = a.conf[cls][p]
            cells.append(f"{tp:3} {fp:3} {fn:3} {tn:3}  {tp + tn:3}/{tp + fp + fn + tn:<3}")
        print(f"  {p:12}" + "".join(f"{c:>28}" for c in cells))


def report(arms, refs, readings, compiled, examined, numbers):
    print(f"observer oracle: {examined} rows, numbers={numbers}")
    for t, _ in TIERS:
        group = [arms[(t, f)] for f in FORMS]
        for cls in SCORED:
            table(f"TIER {t}" + ("" if t == "interp" else
                                 f" (loop form compiled on {sum(1 for (tt, _r) in compiled if tt == t)} rows)"),
                  group, cls)
    for cls in SCORED:
        table("REFERENCE (tier-independent)", refs, cls)
    for cls in SCORED:
        for a in list(arms.values()) + refs:
            m, ag, dis = a.totals(cls)
            print(f"{a.name} {cls}: examined={examined} rows, {cls.lower()}_verdicts={m},"
                  f" agree={ag}, disagree={dis}")
    findings = [(k, v) for k, v in readings.items() if len(set(v.values())) > 1]
    print(f"\nFINDINGS (a predicate reading that differs between tiers or forms): {len(findings)}")
    for (rid, at, p), v in findings:
        print(f"  FINDING {rid}@{at} {p}: " + " ".join(f"{t}/{f}={str(b).lower()}" for (t, f), b in v.items()))
    head = [arms[("interp", "straight")]] + refs
    for cls in SCORED:
        for a in head:
            print(f"\n{a.name} {cls} disagreements ({len(a.disagree[cls])}):")
            for rid, at, p, want, act, cite, why in a.disagree[cls]:
                print(f"  {rid}@{at} {p}: expected={str(want).lower()} actual={str(act).lower()}"
                      f"  [{', '.join(cite)}] {why}")
    rt = {(r, at, p): v for r, at, p, v in arms[("interp", "straight")].eigs}
    if refs[0].eigs:
        print("\nEIGS-DEFINED verdicts (not scored): runtime[interp/straight] vs reference(distance)")
        for r, at, p, v in refs[0].eigs:
            print(f"  {r}@{at} {p}: runtime={str(rt[(r, at, p)]).lower()} reference={str(v).lower()}")


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except HarnessError as e:
        print(f"OBSERVER_ORACLE_ERROR: {e}", file=sys.stderr)
        sys.exit(2)
    except Exception as e:          # an instrument crash is never a verdict
        print(f"OBSERVER_ORACLE_ERROR: internal {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(2)
