#!/usr/bin/env python3
"""Score EigenScript's observer against a ground-truth corpus (#1746).

usage: score.py BINARY [--corpus PATH]

For each corpus row this generates the sequence in Python, emits an
EigenScript program that assigns it to `x`, runs BINARY on it, and reads all
six predicates with the PER-VARIABLE form (`converged of x`) at every
checkpoint. Bare predicates read the most recently assigned binding, the
known probe trap; row `two_vars` exists to catch a harness that uses them.
Every value the runtime holds is compared BIT-EXACTLY with the generator's.

MATH verdicts are the headline score. CONVENTION verdicts (decided only by a
stated tolerance) are scored in their own table. EIGS-DEFINED verdicts are
listed, never scored. The same verdicts are scored for the independent
reference model (reference.py) on the distance signal (the values) and on
the runtime's entropy signal (#1667).

Exit status: 0 when every row ran and was scored, whatever the agreement;
2 on any harness error (missing binary, a program that errors, a missing or
duplicate output line, a value that differs from the generator in any bit,
a schema violation, zero rows, an internal exception). Measurement only:
disagreements never fail the run.
"""
import json
import math
import os
import random
import struct
import subprocess
import sys
import tempfile

import reference

PREDS = ["converged", "stable", "improving", "oscillating", "diverging",
         "equilibrium"]
SCORED = ("MATH", "CONVENTION")
ROW_TIMEOUT = 60
CLAMP = 1e308          # the default build saturates here (EIGS_NUM_MAX)
HERE = os.path.dirname(os.path.abspath(__file__))


class HarnessError(Exception):
    pass


def read_expr(pred):
    """The one place a predicate read is spelled (per-variable form)."""
    return f"{pred} of x"


# --- corpus -----------------------------------------------------------------

def check_verdicts(where, ents, sources):
    if not isinstance(ents, list) or not ents:
        raise HarnessError(f"{where}: needs a list of verdicts")
    labels = [e[0] if e else None for e in ents]
    if labels == ["EIGS-DEFINED"]:
        if len(ents[0]) != 1:
            raise HarnessError(f"{where}: EIGS-DEFINED takes no value")
        return
    if len(set(labels)) != len(labels) or any(l not in SCORED for l in labels):
        raise HarnessError(f"{where}: bad labels {labels}")
    for e in ents:
        if (len(e) != 4 or not isinstance(e[1], bool) or not e[2]
                or any(s not in sources for s in e[2]) or not e[3]):
            raise HarnessError(f"{where}: a {e[0]} verdict needs a bool,"
                               " known sources and a reason")


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
    for k, s in sources.items():
        if not s.get("text") or not s.get("status", "").startswith(("VERIFIED", "UNVERIFIED")):
            raise HarnessError(f"source {k}: needs text and a VERIFIED/UNVERIFIED status")
    seen = set()
    for r in rows:
        rid = r.get("id")
        if not rid or rid in seen:
            raise HarnessError(f"row id missing or duplicated: {rid!r}")
        seen.add(rid)
        for k in ("family", "form", "gen", "n", "checkpoints"):
            if k not in r:
                raise HarnessError(f"{rid}: missing {k}")
        ats = [ck["at"] for ck in r["checkpoints"]]
        if not ats or ats != sorted(set(ats)) or ats[-1] != r["n"] or ats[0] < 1:
            raise HarnessError(f"{rid}: checkpoints {ats} must be increasing"
                               f" and end at n={r['n']}")
        for ck in r["checkpoints"]:
            if sorted(ck["v"]) != sorted(PREDS):
                raise HarnessError(f"{rid}@{ck['at']}: needs all six predicates")
            for p, ents in ck["v"].items():
                check_verdicts(f"{rid}@{ck['at']}.{p}", ents, sources)
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
        xs = [float(eval(gen["expr"], ENV, {"n": i})) for i in range(n + 1)]
    elif k == "recur":
        xs = [gen["x0"]]
        for i in range(1, n + 1):
            xs.append(float(eval(gen["expr"], ENV, {"x": xs[-1], "n": i})))
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
    return [float(v) for v in xs]


def literal(v):
    """Round-trip spelling: float(literal(v)) == v in every bit."""
    if not math.isfinite(v):
        raise HarnessError(f"non-finite literal {v!r}: only affine rows may overflow")
    return repr(v)


def emit(row, xs, ys):
    """Affine rows are emitted as the recurrence itself, so overflow happens
    in the runtime's own arithmetic; every other row assigns literals. Every
    assignment is followed by a V (and Y) line carrying the runtime's value."""
    gen = row["gen"]
    cks = {ck["at"] for ck in row["checkpoints"]}
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
            reads = " ".join("{" + read_expr(p) + "}" for p in PREDS)
            out.append(f'print of f"CK {i} {reads}"')
    out.append(f'print of "ROW_DONE {row["id"]}"')
    return "\n".join(out) + "\n"


# --- running ----------------------------------------------------------------

def bits(v):
    return struct.pack("<d", v)


def check_value(rid, tag, i, want, got):
    if math.isfinite(want):
        if bits(got) != bits(want):
            raise HarnessError(f"{rid}: {tag}_{i} runtime={got!r} generator={want!r}"
                               " (values must agree in every bit)")
    elif got != math.copysign(CLAMP, want):
        raise HarnessError(f"{rid}: {tag}_{i} generator overflowed to {want!r},"
                           f" runtime={got!r} (expected the clamp)")


def run_row(binary, row, xs, ys, tmpdir):
    prog = os.path.join(tmpdir, row["id"] + ".eigs")
    with open(prog, "w") as f:
        f.write(emit(row, xs, ys))
    try:
        p = subprocess.run([binary, prog], capture_output=True, text=True,
                           timeout=ROW_TIMEOUT, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise HarnessError(f"{row['id']}: cannot run {binary}: {e}")
    rid = row["id"]
    lines = p.stdout.splitlines()
    if p.returncode != 0 or p.stderr.strip() or not lines \
            or lines[-1] != f"ROW_DONE {rid}":
        raise HarnessError(f"{rid}: program failed (rc={p.returncode})\n"
                           f"stderr: {p.stderr.strip()[:400]}\n"
                           f"stdout tail: {lines[-3:]}")
    got, vals = {}, {"V": {}, "Y": {}}
    for ln in lines[:-1]:
        f = ln.split()
        if len(f) == 3 and f[0] in vals:
            i = int(f[1])
            if i in vals[f[0]]:
                raise HarnessError(f"{rid}: duplicate {f[0]} line {i}")
            vals[f[0]][i] = float(f[2])
            continue
        if len(f) != 8 or f[0] != "CK":
            raise HarnessError(f"{rid}: unexpected output line {ln!r}")
        at = int(f[1])
        if at in got:
            raise HarnessError(f"{rid}: duplicate checkpoint {at}")
        if any(b not in ("true", "false") for b in f[2:]):
            raise HarnessError(f"{rid}@{at}: non-boolean read {f[2:]}")
        got[at] = dict(zip(PREDS, (b == "true" for b in f[2:])))
    want = [ck["at"] for ck in row["checkpoints"]]
    if sorted(got) != want:
        raise HarnessError(f"{rid}: checkpoints read {sorted(got)}, expected {want}")
    for tag, seq in (("V", xs), ("Y", ys)):
        if seq is None:
            continue
        if sorted(vals[tag]) != list(range(len(seq))):
            raise HarnessError(f"{rid}: {len(vals[tag])} {tag} values read,"
                               f" generator has {len(seq)}")
        for i, w in enumerate(seq):
            check_value(rid, tag, i, w, vals[tag][i])
    return got


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
    declared = {c: sum(1 for r in rows for ck in r["checkpoints"]
                       for ents in ck["v"].values() for e in ents if e[0] == c)
                for c in SCORED}
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
                    arms[0].add(row["id"], at, p, ck["v"][p], got[at][p])
                    arms[1].add(row["id"], at, p, ck["v"][p], ref[p])
                    arms[2].add(row["id"], at, p, ck["v"][p], ref_h[p])
            examined += 1
    if examined != len(rows) or examined == 0:
        raise HarnessError(f"examined {examined} rows of {len(rows)}")
    for arm in arms:
        for c in SCORED:
            if arm.totals(c)[0] != declared[c]:
                raise HarnessError(f"{arm.name} scored {arm.totals(c)[0]} {c}"
                                   f" verdicts, corpus declares {declared[c]}")
    report(arms, examined)
    return 0


def report(arms, examined):
    print(f"observer oracle: {examined} rows")
    for cls in SCORED:
        head = "HEADLINE" if cls == "MATH" else "separate, not the headline"
        print(f"\n{cls} verdicts ({head}): per-predicate TP FP FN TN, agree/total")
        print(f"  {'predicate':12}" + "".join(f"{a.name:>26}" for a in arms))
        for p in PREDS:
            cells = []
            for a in arms:
                tp, fp, fn, tn = a.conf[cls][p]
                cells.append(f"{tp:3} {fp:3} {fn:3} {tn:3}  {tp + tn:3}/{tp + fp + fn + tn:<3}")
            print(f"  {p:12}" + "".join(f"{c:>26}" for c in cells))
        for a in arms:
            m, ag, dis = a.totals(cls)
            print(f"{a.name} {cls}: examined={examined} rows, {cls.lower()}_verdicts={m},"
                  f" agree={ag}, disagree={dis}")
    for cls in SCORED:
        for a in arms:
            print(f"\n{a.name} {cls} disagreements ({len(a.disagree[cls])}):")
            for rid, at, p, want, act, cite, why in a.disagree[cls]:
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
    except Exception as e:          # an instrument crash is never a verdict
        print(f"OBSERVER_ORACLE_ERROR: internal {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(2)
