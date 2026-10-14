#!/usr/bin/env python3
"""Derive the observer oracle's labels from the corpus (#1746).

usage: derive.py [--write]     (prints, or rewrites labels.json)

The corpus states, per row, a generator and ONE property set (limit,
tends_to, bounded, has_trend, periodic, variance_changes) with its
justification. Every label is computed here from those properties, the
generated values and the corpus `definitions` table; nothing per predicate
or per checkpoint is written by hand. score.py refuses a labels.json that
differs from derive(corpus).
"""
import json
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PREDS = ["converged", "stable", "improving", "oscillating", "diverging",
         "equilibrium"]
RTOL = 1e-3          # the observer's dh_zero: settle tolerance and min_delta
SCALE = 1e-3         # the observer's scale: below it tolerances turn absolute
PATIENCE = 10        # the observer's window
FLAGS = ("has_trend", "periodic", "variance_changes")


class HarnessError(Exception):
    pass


# Corpus expressions are checked-in repo data (not user input), evaluated
# with no builtins.
ENV = {"__builtins__": {}, "math": math}


def generate(gen, n):
    k = gen["kind"]
    if k == "affine":
        xs = [gen["x0"]]
        for _ in range(n):
            xs.append(xs[-1] * gen["a"] + gen["b"])
    elif k == "closed":
        code = compile(gen["expr"], "<corpus>", "eval")
        xs = [float(eval(code, ENV, {"n": i})) for i in range(n + 1)]
    elif k == "recur":
        code = compile(gen["expr"], "<corpus>", "eval")
        xs = [gen["x0"]]
        for i in range(1, n + 1):
            xs.append(float(eval(code, ENV, {"x": xs[-1], "n": i})))
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


def eps(v):
    return RTOL * max(abs(v), SCALE)


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
        undecided = any(p[f] is None for f in FLAGS)
        if undecided != bool(r.get("undecided")):
            raise HarnessError(f"{rid}: a null property needs an `undecided` reason, and only then")
    return c


def _tail_settles(row, far, n):
    """CONVENTION converged@n: the tail x_n..x_H stays within eps."""
    p = row["props"]
    if far is None:
        return False, "unbounded"
    h = len(far) - 1
    tail = far[n:]
    if p["limit"] is not None:
        lim = p["limit"]
        worst = max(abs(v - lim) for v in tail)
        return worst <= eps(lim), f"max |x_m - {lim:.6g}| over m in [{n}, {h}] = {worst:.3g} vs eps {eps(lim):.3g}"
    lo, hi = min(tail), max(tail)
    mid = (lo + hi) / 2
    return (hi - lo) / 2 <= eps(mid), f"tail x_{n}..x_{h} spans {hi - lo:.3g} vs 2*eps {2 * eps(mid):.3g}"


def _improving(xs, n):
    """Keras EarlyStopping mode='min', literally, from x_0 with patience."""
    best, last = xs[0], None
    for i in range(1, n + 1):
        if xs[i] < best - eps(best):
            best, last = xs[i], i
    ok = last is not None and last >= max(1, n - PATIENCE + 1)
    at = f"x_{last}" if last is not None else "none after x_0"
    return ok, f"last improvement {at} (best {best:.6g}); window [{max(1, n - PATIENCE + 1)}, {n}]"


def derive_row(row, defs):
    p, why = row["props"], row["why"]
    def cite(pred, cls):                        # MATH adds the row's property sources
        base = defs[(pred, cls)]
        return base + [s for s in row["cite"] if s not in base] if cls == "MATH" else base
    xs = generate(row["gen"], row["n"])
    far = None                                  # horizon H = max(20000, 10n)
    if p["bounded"] and not p["tends_to"]:
        far = generate(row["gen"], max(20000, 10 * row["n"]))
    if p["limit"] is not None:                  # the stated limit must fit the data
        lim = p["limit"]
        if abs(far[-1] - lim) > abs(xs[-1] - lim) + eps(lim):
            raise HarnessError(f"{row['id']}: values move away from the stated limit {lim}")
    flags = [p[f] for f in FLAGS]
    if True in flags:
        eq = ["MATH", False, cite("equilibrium", "MATH"),
              "not stationary: " + ", ".join(f for f in FLAGS if p[f] is True) + f" ({why})"]
    elif None in flags:
        eq = ["EIGS-DEFINED", row["undecided"]]
    else:
        eq = ["MATH", True, cite("equilibrium", "MATH"), f"no trend, constant variance, no periodic fluctuation ({why})"]
    whole = {
        "converged": [["MATH", p["limit"] is not None, cite("converged", "MATH"),
                       (f"limit {p['limit']:.10g}" if p["limit"] is not None else "no finite limit") + f" ({why})"]],
        "diverging": [["MATH", p["tends_to"] is not None, cite("diverging", "MATH"),
                       (f"tends to {p['tends_to']}" if p["tends_to"] else "does not tend to +-inf") + f" ({why})"]],
        "oscillating": [["MATH", p["limit"] is None and p["tends_to"] is None, cite("oscillating", "MATH"),
                         ("no limit and not +-inf" if p["limit"] is None and p["tends_to"] is None
                          else "has a limit or tends to +-inf") + f" ({why})"]],
        "equilibrium": [eq],
        "stable": [["EIGS-DEFINED", "no standard definition (pending the owner, #1754)"]],
    }
    out = {}
    for n in row["checkpoints"]:
        settled, swhy = _tail_settles(row, far, n)
        imp, iwhy = _improving(xs, n)
        v = dict(whole)
        v["converged"] = whole["converged"] + [["CONVENTION", settled, cite("converged", "CONVENTION"), swhy]]
        v["improving"] = [["CONVENTION", imp, cite("improving", "CONVENTION"), iwhy]]
        out[f"{row['id']}@{n}"] = {k: v[k] for k in PREDS}
    return out


def derive(corpus):
    defs = {(d["predicate"], d["class"]): d["cite"] for d in corpus["definitions"]}
    labels = {}
    for row in corpus["rows"]:
        labels.update(derive_row(row, defs))
    return labels


def dump(labels):
    lines = [f"  {json.dumps(k)}: {json.dumps(v, ensure_ascii=False)}" for k, v in labels.items()]
    return "{\n" + ",\n".join(lines) + "\n}\n"


if __name__ == "__main__":
    try:
        text = dump(derive(load_corpus(os.path.join(HERE, "corpus.json"))))
    except HarnessError as e:
        print(f"OBSERVER_ORACLE_ERROR: {e}", file=sys.stderr)
        sys.exit(2)
    if sys.argv[1:] == ["--write"]:
        with open(os.path.join(HERE, "labels.json"), "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
