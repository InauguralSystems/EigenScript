#!/usr/bin/env python3
"""Derive the observer oracle's labels from the corpus (#1746).

usage: derive.py [--write]     (prints, or rewrites labels.json)

The corpus states, per row, a generator and ONE property set (limit,
tends_to, bounded, deterministic; random-process rows add has_trend,
periodic, variance_changes) with its justification. The mathematical facts
are CERTIFIED offline by certify.py (sympy), which writes certificate.json
with the sha256 of each row's generator and properties; derive refuses a
missing or stale certificate, and needs no sympy itself. Every label is
computed here from the certified properties, the generated values and the
corpus `definitions` table; nothing per predicate or per checkpoint is
written by hand. derive() asserts its own postconditions (the converged =>
stable lattice, and where EIGS-DEFINED may appear), and score.py refuses a
labels.json that differs from derive(corpus).
"""
import hashlib
import json
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PREDS = ["converged", "stable", "improving", "oscillating", "diverging",
         "equilibrium"]
RTOL = 1e-3          # the observer's dh_zero: settle tolerance and min_delta
BAND = 1e-2          # the observer's dh_small: OUR choice of settling band
SCALE = 1e-3         # the observer's scale: below it tolerances turn absolute
PATIENCE = 10        # the observer's window
FLAGS = ("has_trend", "periodic", "variance_changes")
RANDOM_KINDS = ("noise", "walk")            # realizations of random processes
INT64_MIN = -2 ** 63


class HarnessError(Exception):
    pass


# Corpus expressions are checked-in repo data (not user input), evaluated
# with no builtins, compiled once into a function of n (closed) or x, n (recur).
ENV = {"__builtins__": {}, "math": math,
       "step": lambda n, c: 1.0 if n >= c else 0.0}    # certify.py: Heaviside(n - c + 1/2)


def _fn(gen):
    args = "n" if gen["kind"] == "closed" else "x, n"
    return eval(f"lambda {args}: ({gen['expr']})", ENV)


def generate(gen, n):
    """The row's values x_0..x_n: floats, or exact Python ints for an int row."""
    k, num = gen["kind"], (int if gen.get("int") else float)
    if k == "affine":
        xs = [gen["x0"]]
        for _ in range(n):
            xs.append(xs[-1] * gen["a"] + gen["b"])
    elif k == "closed":
        f = _fn(gen)
        xs = [f(i) for i in range(n + 1)]
    elif k == "recur":
        f = _fn(gen)
        xs = [gen["x0"]]
        for i in range(1, n + 1):
            xs.append(float(f(xs[-1], i)))
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
    if num is int and any(not isinstance(v, int) or not INT64_MIN <= v < 2 ** 63 for v in xs):
        raise HarnessError(f"an int row must generate int64 values: {gen}")
    return [num(v) for v in xs]


def eps(v):
    return RTOL * max(abs(v), SCALE)


def band(v):
    return BAND * max(abs(v), SCALE)


def row_hash(row):
    """What a certificate vouches for: the generator, the stated properties
    and any symbolic form or manual argument the certifier used."""
    basis = {k: row.get(k) for k in ("gen", "props", "sym", "manual")}
    return hashlib.sha256(json.dumps(basis, sort_keys=True).encode()).hexdigest()


def load_corpus(path):
    try:
        with open(path) as f:
            c = json.load(f)
    except (OSError, ValueError) as e:
        raise HarnessError(f"cannot load corpus {path}: {e}")
    rows, sources = c.get("rows"), c.get("sources", {})
    if not isinstance(rows, list) or not rows:
        raise HarnessError("corpus has no rows")
    for k, s in sources.items():
        if not s.get("text") or not s.get("status", "").startswith(("VERIFIED", "UNVERIFIED")):
            raise HarnessError(f"source {k}: needs text and a VERIFIED/UNVERIFIED status")
    table = {(d["predicate"], d["class"]) for d in c.get("definitions", [])}
    for d in c.get("definitions", []):
        if any(s not in sources for s in d["cite"]):
            raise HarnessError(f"definition {d['predicate']}/{d['class']}: unknown source")
    if {p for p, _ in table} != set(PREDS):
        raise HarnessError("definitions table must cover all six predicates")
    seen = set()
    for r in rows:
        rid = r.get("id")
        if not rid or rid in seen:
            raise HarnessError(f"row id missing or duplicated: {rid!r}")
        seen.add(rid)
        for k in ("family", "form", "gen", "n", "checkpoints", "props", "why", "cite"):
            if k not in r:
                raise HarnessError(f"{rid}: missing {k}")
        ats, p = r["checkpoints"], r["props"]
        if not ats or ats != sorted(set(ats)) or ats[-1] != r["n"] or ats[0] < 1:
            raise HarnessError(f"{rid}: checkpoints {ats} must be increasing and end at n")
        if any(s not in sources for s in r["cite"]) or not r["why"]:
            raise HarnessError(f"{rid}: properties need a reason and known sources")
        if p["limit"] is not None and (p["tends_to"] is not None or not p["bounded"]):
            raise HarnessError(f"{rid}: a limit excludes tends_to and unboundedness")
        if p["tends_to"] not in (None, "+inf", "-inf") or (p["tends_to"] and p["bounded"]):
            raise HarnessError(f"{rid}: bad tends_to {p['tends_to']!r}")
        if p["deterministic"] != (r["gen"]["kind"] not in RANDOM_KINDS):
            raise HarnessError(f"{rid}: deterministic={p['deterministic']} contradicts"
                               f" generator kind {r['gen']['kind']!r}")
        has = [f in p for f in FLAGS]
        if p["deterministic"] and any(has):
            raise HarnessError(f"{rid}: trend/periodic/variance flags decide nothing on a"
                               " deterministic row; remove them")
        if not p["deterministic"]:
            if not all(has):
                raise HarnessError(f"{rid}: a random-process row needs all three NIST flags")
            if any(p[f] for f in FLAGS) and "NIST_6442" not in r["cite"]:
                raise HarnessError(f"{rid}: a true trend/periodic/variance flag needs NIST_6442")
            if any(p[f] is None for f in FLAGS) != bool(r.get("undecided")):
                raise HarnessError(f"{rid}: a null flag needs an `undecided` reason, and only then")
    return c


def load_certificates(corpus, path):
    """certify.py's verdicts, refused unless every row has one whose hash
    matches the row as it stands now (and no certificate names a row the
    corpus lacks)."""
    try:
        with open(path) as f:
            certs = json.load(f)["rows"]
    except (OSError, ValueError, KeyError) as e:
        raise HarnessError(f"cannot load certificates {path}: {e}; re-run certify.py")
    ids = {r["id"] for r in corpus["rows"]}
    for rid in sorted(set(certs) - ids):
        raise HarnessError(f"certificate for {rid}, which the corpus lacks: stale; re-run certify.py")
    for r in corpus["rows"]:
        c = certs.get(r["id"])
        if c is None:
            raise HarnessError(f"{r['id']}: no certificate; re-run certify.py")
        if c.get("hash") != row_hash(r):
            raise HarnessError(f"{r['id']}: stale certificate (the row changed since it was"
                               " certified); re-run certify.py")
        if c.get("kind") not in ("symbolic", "exact", "fixed-point", "manual"):
            raise HarnessError(f"{r['id']}: certificate kind {c.get('kind')!r}")
        if r["props"]["deterministic"] and not isinstance(c.get("constant"), bool):
            raise HarnessError(f"{r['id']}: certificate does not decide constancy")
    return certs


def _tail_within(row, far, n, radius, name):
    """CONVENTION converged/stable@n: the tail x_n..x_H stays within
    radius(L) of the limit, or (no limit) fits a ball of radius(centre)."""
    p = row["props"]
    if far is None:
        return False, "unbounded"
    h, tail = len(far) - 1, far[n:]
    if p["limit"] is not None:
        lim = p["limit"]
        worst = max(abs(v - lim) for v in tail)
        return worst <= radius(lim), f"max |x_m - {lim:.6g}| over m in [{n}, {h}] = {worst:.3g} vs {name} {radius(lim):.3g}"
    lo, hi = min(tail), max(tail)
    mid = (lo + hi) / 2
    return (hi - lo) / 2 <= radius(mid), f"tail x_{n}..x_{h} spans {hi - lo:.3g} vs 2*{name} {2 * radius(mid):.3g}"


def _improving(xs, n, bounded):
    """Keras EarlyStopping mode='min' from x_0 with patience, with ONE deliberate
    deviation: Keras starts best=inf so epoch 0 always counts as an improvement;
    here x_0 is the baseline and never counts (a value cannot improve on nothing).
    #1754 (corrected): a new best counts only for a BOUNDED sequence (Hardy
    Sec. 62: neither diverging nor oscillating infinitely)."""
    best, last = xs[0], None
    for i in range(1, n + 1):
        if xs[i] < best - eps(best):
            best, last = xs[i], i
    ok = last is not None and last >= max(1, n - PATIENCE + 1)
    at = f"x_{last}" if last is not None else "none after x_0"
    why = f"last improvement {at} (best {best:.6g}); window [{max(1, n - PATIENCE + 1)}, {n}]"
    return (ok and bounded), why + ("" if bounded else "; unbounded, so not improving")


def _equilibrium(row, cert, cite):
    p, why = row["props"], row["why"]
    if p["deterministic"]:
        if cert["constant"]:
            return ["MATH", True, cite, f"a constant sequence: certified constant ({why})"]
        return ["MATH", False, cite, "deterministic and certified non-constant: as a"
                " degenerate process its mean x_n is not constant, so it is not stationary" + f" ({why})"]
    if True in [p[f] for f in FLAGS]:
        return ["MATH", False, cite, "not stationary: " + ", ".join(f for f in FLAGS if p[f]) + f" ({why})"]
    if None in [p[f] for f in FLAGS]:
        return ["EIGS-DEFINED", row["undecided"]]
    return ["MATH", True, cite, f"no trend, constant variance, no periodic fluctuation ({why})"]


def derive_row(row, cert, defs):
    p, why = row["props"], row["why"]
    def cite(pred, cls):                        # MATH adds the row's property sources
        base = defs[(pred, cls)]
        return base + [s for s in row["cite"] if s not in base] if cls == "MATH" else base
    xs = generate(row["gen"], row["n"])
    far = None                                  # horizon H = max(20000, 10n)
    if p["bounded"] and not p["tends_to"]:
        far = generate(row["gen"], max(20000, 10 * row["n"]))
    lim, tends = p["limit"], p["tends_to"]
    whole = {
        "converged": [["MATH", lim is not None, cite("converged", "MATH"),
                       (f"limit {lim:.10g}" if lim is not None else "no finite limit") + f" ({why})"]],
        "diverging": [["MATH", tends is not None, cite("diverging", "MATH"),
                       (f"tends to {tends}" if tends else "does not tend to +-inf") + f" ({why})"]],
        "oscillating": [["MATH", lim is None and tends is None, cite("oscillating", "MATH"),
                         ("no limit and not +-inf" if lim is None and tends is None
                          else "has a limit or tends to +-inf") + f" ({why})"]],
        "equilibrium": [_equilibrium(row, cert, cite("equilibrium", "MATH"))],
    }
    out = {}
    for n in row["checkpoints"]:
        settled, swhy = _tail_within(row, far, n, eps, "eps")
        inband, bwhy = _tail_within(row, far, n, band, "band")
        imp, iwhy = _improving(xs, n, p["bounded"])
        v = dict(whole)
        v["converged"] = whole["converged"] + [["CONVENTION", settled, cite("converged", "CONVENTION"), swhy]]
        v["stable"] = [["CONVENTION", inband, cite("stable", "CONVENTION"), bwhy]]
        v["improving"] = [["CONVENTION", imp, cite("improving", "CONVENTION"), iwhy]]
        out[f"{row['id']}@{n}"] = {k: v[k] for k in PREDS}
    return out


def postconditions(corpus, labels):
    """The derivation's own invariants, checked on its output: CONVENTION
    converged implies CONVENTION stable (the band is wider than eps), and
    EIGS-DEFINED appears only where the definitions table allows it."""
    rows = {r["id"]: r for r in corpus["rows"]}
    for key, preds in labels.items():
        row = rows[key.rsplit("@", 1)[0]]
        conv = [e for e in preds["converged"] if e[0] == "CONVENTION"]
        st = [e for e in preds["stable"] if e[0] == "CONVENTION"]
        if conv and conv[0][1] and not (st and st[0][1]):
            raise HarnessError(f"{key}: lattice broken: CONVENTION converged without stable")
        for p, ents in preds.items():
            if ents[0][0] != "EIGS-DEFINED":
                continue
            props = row["props"]
            flags = [props.get(f) for f in FLAGS]
            if not (p == "equilibrium" and not props["deterministic"]
                    and True not in flags and None in flags and row.get("undecided")):
                raise HarnessError(f"{key}.{p}: EIGS-DEFINED where a standard decides it")


def derive(corpus, certs):
    defs = {(d["predicate"], d["class"]): d["cite"] for d in corpus["definitions"]}
    labels = {}
    for row in corpus["rows"]:
        labels.update(derive_row(row, certs[row["id"]], defs))
    postconditions(corpus, labels)
    return labels


def dump(labels):
    lines = [f"  {json.dumps(k)}: {json.dumps(v, ensure_ascii=False)}" for k, v in labels.items()]
    return "{\n" + ",\n".join(lines) + "\n}\n"


if __name__ == "__main__":
    try:
        corpus = load_corpus(os.path.join(HERE, "corpus.json"))
        text = dump(derive(corpus, load_certificates(corpus, os.path.join(HERE, "certificate.json"))))
    except HarnessError as e:
        print(f"OBSERVER_ORACLE_ERROR: {e}", file=sys.stderr)
        sys.exit(2)
    if sys.argv[1:] == ["--write"]:
        with open(os.path.join(HERE, "labels.json"), "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
