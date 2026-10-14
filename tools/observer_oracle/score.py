#!/usr/bin/env python3
"""Score EigenScript's observer against a ground-truth corpus (#1746).

usage: score.py BINARY [--corpus PATH]

For each corpus row this generates the sequence in Python, emits an
EigenScript program that assigns it to `x`, runs BINARY on it, and reads all
six predicates with the PER-VARIABLE form (`converged of x`) at every
checkpoint. Bare predicates read the most recently assigned binding, the
known probe trap; row `two_vars` exists to catch a harness that uses them.

Only MATH verdicts are scored. EIGS-DEFINED verdicts are listed separately.
The same verdicts are scored for the independent reference model
(reference.py) on the distance signal (the values) and on the runtime's
entropy signal (#1667).

Exit status: 0 when every row ran and was scored, whatever the agreement;
2 on any harness error (missing binary, a program that errors, a missing or
duplicate checkpoint line, a schema violation, zero rows). Measurement only:
disagreements never fail the run.
"""
import json
import math
import os
import random
import subprocess
import sys
import tempfile

import reference

PREDS = ["converged", "stable", "improving", "oscillating", "diverging",
         "equilibrium"]
LABELS = ("MATH", "EIGS-DEFINED")
ROW_TIMEOUT = 60
HERE = os.path.dirname(os.path.abspath(__file__))


class HarnessError(Exception):
    pass


def read_expr(pred):
    """The one place a predicate read is spelled (per-variable form)."""
    return f"{pred} of x"


# --- corpus -----------------------------------------------------------------

def load_corpus(path):
    try:
        with open(path) as f:
            c = json.load(f)
    except (OSError, ValueError) as e:
        raise HarnessError(f"cannot load corpus {path}: {e}")
    rows = c.get("rows")
    if not isinstance(rows, list) or not rows:
        raise HarnessError("corpus has no rows")
    sources = c.get("sources", {})
    seen = set()
    for r in rows:
        rid = r.get("id")
        if not rid or rid in seen:
            raise HarnessError(f"row id missing or duplicated: {rid!r}")
        seen.add(rid)
        for k in ("family", "form", "gen", "n", "checkpoints"):
            if k not in r:
                raise HarnessError(f"{rid}: missing {k}")
        cks = r["checkpoints"]
        if not cks:
            raise HarnessError(f"{rid}: no checkpoints")
        ats = [ck["at"] for ck in cks]
        if ats != sorted(set(ats)) or ats[-1] != r["n"] or ats[0] < 1:
            raise HarnessError(f"{rid}: checkpoints {ats} must be increasing"
                               f" and end at n={r['n']}")
        for ck in cks:
            if sorted(ck["v"]) != sorted(PREDS):
                raise HarnessError(f"{rid}@{ck['at']}: needs all six predicates")
            for p, v in ck["v"].items():
                if not v or v[0] not in LABELS:
                    raise HarnessError(f"{rid}@{ck['at']}.{p}: bad label {v!r}")
                if v[0] == "MATH":
                    if (len(v) != 4 or not isinstance(v[1], bool) or not v[2]
                            or any(s not in sources for s in v[2]) or not v[3]):
                        raise HarnessError(f"{rid}@{ck['at']}.{p}: a MATH verdict"
                                           " needs a bool, known sources and a reason")
                elif len(v) != 1:
                    raise HarnessError(f"{rid}@{ck['at']}.{p}: EIGS-DEFINED takes no value")
    return c


# Corpus expressions are checked-in data, evaluated with no builtins.
ENV = {"__builtins__": {}, "math": math}


def generate(gen, n):
    k = gen["kind"]
    if k == "affine":
        xs = [gen["x0"]]
        for _ in range(n):
            xs.append(xs[-1] * gen["a"] + gen["b"])
    elif k == "closed":
        xs = [float(eval(gen["expr"], ENV, {"n": i}))
              for i in range(n + 1)]
    elif k == "recur":
        xs = [gen["x0"]]
        for i in range(1, n + 1):
            xs.append(float(eval(gen["expr"], ENV,
                                 {"x": xs[-1], "n": i})))
    elif k == "cycle":
        vs = gen["values"]
        xs = [vs[i % len(vs)] for i in range(n + 1)]
    elif k == "noise":
        rng = random.Random(gen["seed"])
        xs = [gen["center"] + gen["amp"] * rng.uniform(-1.0, 1.0)
              for _ in range(n + 1)]
    elif k == "walk":
        rng = random.Random(gen["seed"])
        xs = [gen["x0"]]
        for _ in range(n):
            xs.append(xs[-1] + (gen["step"] if rng.random() < 0.5 else -gen["step"]))
    else:
        raise HarnessError(f"unknown generator kind {k!r}")
    return xs


def literal(v):
    if not math.isfinite(v):
        raise HarnessError(f"non-finite literal {v!r}: only affine rows may overflow")
    return repr(float(v))


def emit(row, xs, ys):
    """Affine rows are emitted as the recurrence itself, so overflow happens
    in the runtime's own arithmetic; every other row assigns literals."""
    gen = row["gen"]
    cks = {ck["at"] for ck in row["checkpoints"]}
    out = []
    for i, v in enumerate(xs):
        if gen["kind"] == "affine" and i > 0:
            out.append(f"x is x * {literal(gen['a'])} + {literal(gen['b'])}")
        else:
            out.append(f"x is {literal(v)}")
        if ys is not None:
            out.append(f"y is {literal(ys[i])}")
        if i in cks:
            reads = " ".join("{" + read_expr(p) + "}" for p in PREDS)
            out.append(f'print of f"CK {i} {reads} {{report of x}} {{x}}"')
    out.append(f'print of "ROW_DONE {row["id"]}"')
    return "\n".join(out) + "\n"


# --- running ----------------------------------------------------------------

def run_row(binary, row, xs, ys, tmpdir):
    prog = os.path.join(tmpdir, row["id"] + ".eigs")
    with open(prog, "w") as f:
        f.write(emit(row, xs, ys))
    try:
        p = subprocess.run([binary, prog], capture_output=True, text=True,
                           timeout=ROW_TIMEOUT, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise HarnessError(f"{row['id']}: cannot run {binary}: {e}")
    lines = p.stdout.splitlines()
    if p.returncode != 0 or p.stderr.strip() or not lines \
            or lines[-1] != f"ROW_DONE {row['id']}":
        raise HarnessError(f"{row['id']}: program failed (rc={p.returncode})\n"
                           f"stderr: {p.stderr.strip()[:400]}\n"
                           f"stdout tail: {lines[-3:]}")
    got = {}
    for ln in lines[:-1]:
        f = ln.split()
        if len(f) != 10 or f[0] != "CK":
            raise HarnessError(f"{row['id']}: unexpected output line {ln!r}")
        at = int(f[1])
        if at in got:
            raise HarnessError(f"{row['id']}: duplicate checkpoint {at}")
        bools = f[2:8]
        if any(b not in ("true", "false") for b in bools):
            raise HarnessError(f"{row['id']}@{at}: non-boolean read {bools}")
        got[at] = {"pred": dict(zip(PREDS, (b == "true" for b in bools))),
                   "report": f[8], "x": float(f[9])}
    want = [ck["at"] for ck in row["checkpoints"]]
    if sorted(got) != want:
        raise HarnessError(f"{row['id']}: checkpoints read {sorted(got)}, expected {want}")
    for at in want:                       # the runtime saw the intended values
        py, rt = xs[at], got[at]["x"]
        if math.isfinite(py) and abs(py) < 1e308:
            if abs(rt - py) > 1e-9 * max(1.0, abs(py)):
                raise HarnessError(f"{row['id']}@{at}: runtime x={rt!r}, generator {py!r}")
        elif not abs(rt) >= 1e308:
            raise HarnessError(f"{row['id']}@{at}: generator overflowed, runtime x={rt!r}")
    return got


# --- scoring ----------------------------------------------------------------

class Arm:
    def __init__(self, name):
        self.name = name
        self.conf = {p: [0, 0, 0, 0] for p in PREDS}   # TP FP FN TN
        self.disagree = []
        self.eigs = []

    def add(self, rid, at, pred, verdict, actual):
        if verdict[0] != "MATH":
            self.eigs.append((rid, at, pred, actual))
            return
        want = verdict[1]
        idx = {(True, True): 0, (False, True): 1, (True, False): 2,
               (False, False): 3}[(want, actual)]
        self.conf[pred][idx] += 1
        if want != actual:
            self.disagree.append((rid, at, pred, want, actual, verdict[2], verdict[3]))

    def totals(self):
        m = sum(sum(c) for c in self.conf.values())
        a = sum(c[0] + c[3] for c in self.conf.values())
        return m, a, m - a


def main(argv):
    args = argv[1:]
    corpus_path = os.path.join(HERE, "corpus.json")
    if "--corpus" in args:
        i = args.index("--corpus")
        corpus_path = args[i + 1]
        del args[i:i + 2]
    if len(args) != 1:
        raise HarnessError("usage: score.py BINARY [--corpus PATH]")
    binary = os.path.abspath(args[0])
    if not (os.path.isfile(binary) and os.access(binary, os.X_OK)):
        raise HarnessError(f"binary not found or not executable: {binary}")
    corpus = load_corpus(corpus_path)
    rows = corpus["rows"]
    declared_math = sum(1 for r in rows for ck in r["checkpoints"]
                        for v in ck["v"].values() if v[0] == "MATH")
    arms = [Arm("RUNTIME"), Arm("REFERENCE"), Arm("REFERENCE_ENTROPY")]
    examined = 0
    with tempfile.TemporaryDirectory(prefix="obs_oracle_") as tmp:
        for row in rows:
            xs = generate(row["gen"], row["n"])
            ys = generate(row["second"], row["n"]) if "second" in row else None
            got = run_row(binary, row, xs, ys, tmp)
            hs = reference.entropy_signal(xs)
            for ck in row["checkpoints"]:
                at = ck["at"]
                ref = reference.classify(xs, at)
                ref_h = reference.classify(hs, at)
                for p in PREDS:
                    arms[0].add(row["id"], at, p, ck["v"][p], got[at]["pred"][p])
                    arms[1].add(row["id"], at, p, ck["v"][p], ref[p])
                    arms[2].add(row["id"], at, p, ck["v"][p], ref_h[p])
            examined += 1
    if examined != len(rows) or examined == 0:
        raise HarnessError(f"examined {examined} rows of {len(rows)}")
    for arm in arms:
        if arm.totals()[0] != declared_math:
            raise HarnessError(f"{arm.name} scored {arm.totals()[0]} MATH verdicts,"
                               f" corpus declares {declared_math}")
    report(corpus, arms, examined)
    return 0


def report(corpus, arms, examined):
    print(f"observer oracle: {examined} rows, corpus {corpus.get('schema')}")
    print("\nPer-predicate confusion vs MATH verdicts (TP FP FN TN, agree/total):")
    print(f"  {'predicate':12}" + "".join(f"{a.name:>26}" for a in arms))
    for p in PREDS:
        cells = []
        for a in arms:
            tp, fp, fn, tn = a.conf[p]
            tot = tp + fp + fn + tn
            cells.append(f"{tp:3} {fp:3} {fn:3} {tn:3}  {tp + tn:3}/{tot:<3}")
        print(f"  {p:12}" + "".join(f"{c:>26}" for c in cells))
    for a in arms:
        m, ag, dis = a.totals()
        print(f"{a.name}: examined={examined} rows, math_verdicts={m}, agree={ag}, disagree={dis}")
    for a in arms:
        print(f"\n{a.name} disagreements ({len(a.disagree)}):")
        for rid, at, p, want, act, cite, why in a.disagree:
            print(f"  {rid}@{at} {p}: expected={str(want).lower()} actual={str(act).lower()}"
                  f"  [{', '.join(cite)}] {why}")
    print("\nEIGS-DEFINED verdicts (not scored): runtime vs reference(distance)")
    rt = {(r, at, p): v for r, at, p, v in arms[0].eigs}
    by_pred = {}
    for r, at, p, v in arms[1].eigs:
        by_pred.setdefault(p, []).append((r, at, rt[(r, at, p)], v))
    for p, items in by_pred.items():
        same = sum(1 for _, _, a, b in items if a == b)
        print(f"  {p}: {len(items)} verdicts, runtime==reference on {same}")
        for r, at, a, b in items:
            if a != b:
                print(f"    {r}@{at}: runtime={str(a).lower()} reference={str(b).lower()}")


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except HarnessError as e:
        print(f"OBSERVER_ORACLE_ERROR: {e}", file=sys.stderr)
        sys.exit(2)
