#!/usr/bin/env python3
"""Derive the observer oracle's labels from the corpus (#1746).

usage: derive.py [--write]     (prints, or rewrites labels.json)

The corpus states, per row, a generator (gen.py) and ONE property set
(limit, tends_to, bounded, deterministic; a random-process row adds the
NIST flags, which must equal the ones its process kind implies) with its
justification. certify.py (offline, sympy) certifies the properties into
certificate.json, keyed by the row and by the sha256 of gen.py and
certify.py; derive refuses a missing or stale certificate and needs no
sympy. Each predicate is scored against ONE question: its single scored
definition in the corpus `definitions` table. A `reported` definition (MATH
"has a limit") becomes a label column that is printed, never scored. Every
label is computed here from the certified properties, the generated values
and that table; nothing per predicate or checkpoint is written by hand.
derive() asserts its postconditions (one entry per predicate, of its scored
class; CONVENTION converged implies stable), and score.py refuses a
labels.json that differs from derive(corpus).
"""
import hashlib
import json
import os
import sys

from gen import HarnessError, RANDOM_KINDS, generate

HERE = os.path.dirname(os.path.abspath(__file__))
PREDS = ["converged", "stable", "improving", "oscillating", "diverging", "equilibrium"]
RTOL = 1e-3          # the observer's dh_zero: settle tolerance and min_delta
BAND = 1e-2          # the observer's dh_small: OUR choice of settling band
SCALE = 1e-3         # the observer's scale: below it tolerances turn absolute
PATIENCE = 10        # the observer's window
FLAGS = ("has_trend", "periodic", "variance_changes")
# NIST 6.4.4.2 flags follow from the process kind; a row may not choose them.
PROCESS = {"noise": ((False, False, False), "iid noise with a fixed centre and amplitude is"
                     " stationary: no trend, no periodic fluctuation, constant variance"),
           "walk": ((False, False, True), "a random walk x_0 + (n iid steps) has Var x_n ="
                    " n sigma^2, so its variance changes; its mean stays x_0 (no trend)")}
CAPABILITIES = ("ieee", "int64")
NAN_WHY = ("x_n is NaN: IEEE 754 invalid operation, an undefined value (#1758 O2, #1746: every"
           " predicate is false while the current value is NaN)")


def eps(v):
    return RTOL * max(abs(v), SCALE)


def band(v):
    return BAND * max(abs(v), SCALE)


def code_hash():
    """The code that gives a row its meaning: the generator and the certifier."""
    h = hashlib.sha256()
    for name in ("gen.py", "certify.py"):
        with open(os.path.join(HERE, name), "rb") as f:
            h.update(f.read())
    return h.hexdigest()


def row_hash(row, code):
    """What a certificate vouches for: the generator, the stated properties,
    any manual argument, and the code that reads them."""
    basis = {k: row.get(k) for k in ("gen", "props", "manual")}
    return hashlib.sha256((json.dumps(basis, sort_keys=True) + code).encode()).hexdigest()


def scored_classes(corpus):
    """predicate -> its one scored class; reported (predicate, class) -> column."""
    scored, reported = {}, {}
    for d in corpus["definitions"]:
        if d.get("reported"):
            reported[(d["predicate"], d["class"])] = d["column"]
        elif d["predicate"] in scored:
            raise HarnessError(f"{d['predicate']}: two scored definitions; score one question")
        else:
            scored[d["predicate"]] = d["class"]
    return scored, reported


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
    for d in c.get("definitions", []):
        if any(s not in sources for s in d["cite"]) or (d["predicate"], d["class"]) not in RULES:
            raise HarnessError(f"definition {d['predicate']}/{d['class']}: unknown source or no rule")
    if set(scored_classes(c)[0]) != set(PREDS):
        raise HarnessError("every predicate needs exactly one scored definition")
    seen = set()
    for r in rows:
        rid = r.get("id")
        if not rid or rid in seen:
            raise HarnessError(f"row id missing or duplicated: {rid!r}")
        seen.add(rid)
        for k in ("family", "form", "gen", "n", "checkpoints", "props", "why", "cite"):
            if k not in r:
                raise HarnessError(f"{rid}: missing {k}")
        ats, p, g = r["checkpoints"], r["props"], r["gen"]
        if not ats or ats != sorted(set(ats)) or ats[-1] != r["n"] or ats[0] < 1:
            raise HarnessError(f"{rid}: checkpoints {ats} must be increasing and end at n")
        if any(s not in sources for s in r["cite"]) or not r["why"]:
            raise HarnessError(f"{rid}: properties need a reason and known sources")
        if r.get("capability", "ieee") not in CAPABILITIES:
            raise HarnessError(f"{rid}: unknown capability {r['capability']!r}")
        if g["kind"] == "pieces" and not ("x0" in g["pieces"][0] and all(
                isinstance(q.get("steps"), int) and q["steps"] > 0 for q in g["pieces"][:-1])):
            raise HarnessError(f"{rid}: the first piece needs x0 and every piece but the last `steps`")
        if p["tends_to"] not in (None, "+inf", "-inf") or (p["tends_to"] and (p["bounded"] or p["limit"] is not None)):
            raise HarnessError(f"{rid}: tends_to {p['tends_to']!r} excludes a limit and boundedness")
        if p["deterministic"] != (g["kind"] not in RANDOM_KINDS):
            raise HarnessError(f"{rid}: deterministic={p['deterministic']} contradicts"
                               f" generator kind {g['kind']!r}")
        if p["deterministic"]:
            if any(f in p for f in FLAGS):
                raise HarnessError(f"{rid}: trend/periodic/variance flags decide nothing on a"
                                   " deterministic row; remove them")
            continue
        want, reason = PROCESS[g["kind"]]
        if [p.get(f) for f in FLAGS] != list(want):
            raise HarnessError(f"{rid}: flags {dict((f, p.get(f)) for f in FLAGS)} contradict the"
                               f" {g['kind']} process, which gives {dict(zip(FLAGS, want))}: {reason}")
        if any(want) and "NIST_6442" not in r["cite"]:
            raise HarnessError(f"{rid}: a true trend/periodic/variance flag needs NIST_6442")
    return c


def load_certificates(corpus, path):
    """certify.py's verdicts, refused unless every row has one whose hash
    matches the row and the generator/certifier code as they stand now (and
    no certificate names a row the corpus lacks)."""
    try:
        with open(path) as f:
            certs = json.load(f)["rows"]
    except (OSError, ValueError, KeyError) as e:
        raise HarnessError(f"cannot load certificates {path}: {e}; re-run certify.py")
    ids, code = {r["id"] for r in corpus["rows"]}, code_hash()
    for rid in sorted(set(certs) - ids):
        raise HarnessError(f"certificate for {rid}, which the corpus lacks: stale; re-run certify.py")
    for r in corpus["rows"]:
        c = certs.get(r["id"])
        if c is None:
            raise HarnessError(f"{r['id']}: no certificate; re-run certify.py")
        if c.get("hash") != row_hash(r, code):
            raise HarnessError(f"{r['id']}: stale certificate (the row, gen.py or certify.py changed"
                               " since it was certified); re-run certify.py")
        if c.get("kind") not in ("symbolic", "exact", "fixed-point", "ieee", "manual"):
            raise HarnessError(f"{r['id']}: certificate kind {c.get('kind')!r}")
        if r["props"]["deterministic"] and not isinstance(c.get("constant"), bool):
            raise HarnessError(f"{r['id']}: certificate does not decide constancy")
    return certs


def _tail_within(row, far, n, radius, name):
    """CONVENTION converged/stable@n: the tail x_n..x_H stays within
    radius(L) of the limit, or (no limit) fits a ball of radius(centre)."""
    p = row["props"]
    if far is None:
        return False, "tends to " + p["tends_to"] if p["tends_to"] else "unbounded"
    h, tail = len(far) - 1, far[n:]
    if any(v != v for v in tail):
        return False, f"x_m is NaN for some m in [{n}, {h}]"
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


def _equilibrium(row, cert):
    p, why = row["props"], row["why"]
    if p["deterministic"]:
        if cert["constant"]:
            return True, f"a constant sequence: certified constant ({why})"
        return False, ("deterministic and certified non-constant: as a degenerate process its"
                       f" mean x_n is not constant, so it is not stationary ({why})")
    if any(p[f] for f in FLAGS):
        return False, "not stationary: " + ", ".join(f for f in FLAGS if p[f]) + f" ({why})"
    return True, f"no trend, constant variance, no periodic fluctuation ({why})"


def _rules(row, cert, xs, far, n):
    """Every (predicate, class) question the definitions table may ask, at n."""
    p, why = row["props"], row["why"]
    lim, tends = p["limit"], p["tends_to"]
    return {
        ("converged", "MATH"): (lim is not None, (f"limit {lim:.10g}" if lim is not None
                                                  else "no finite limit") + f" ({why})"),
        ("converged", "CONVENTION"): _tail_within(row, far, n, eps, "eps"),
        ("stable", "CONVENTION"): _tail_within(row, far, n, band, "band"),
        ("improving", "CONVENTION"): _improving(xs, n, p["bounded"]),
        ("oscillating", "MATH"): (lim is None and tends is None, ("no limit and not +-inf" if lim is None
                                  and tends is None else "has a limit or tends to +-inf") + f" ({why})"),
        ("diverging", "MATH"): (tends is not None, (f"tends to {tends}" if tends
                                                    else "does not tend to +-inf") + f" ({why})"),
        ("equilibrium", "MATH"): _equilibrium(row, cert),
    }


RULES = {("converged", "MATH"), ("converged", "CONVENTION"), ("stable", "CONVENTION"),
         ("improving", "CONVENTION"), ("oscillating", "MATH"), ("diverging", "MATH"),
         ("equilibrium", "MATH")}           # the keys _rules answers


def derive_row(row, cert, defs, scored, reported):
    p = row["props"]
    def cite(pred, cls):                        # MATH adds the row's property sources
        base = defs[(pred, cls)]
        return base + [s for s in row["cite"] if s not in base] if cls == "MATH" else base
    xs = generate(row["gen"], row["n"])
    nan_at = next((i for i, v in enumerate(xs) if v != v), None)
    if nan_at is not None and row["checkpoints"][0] < nan_at:
        raise HarnessError(f"{row['id']}: checkpoint {row['checkpoints'][0]} precedes the NaN at"
                           f" {nan_at}; no standard decides the whole-sequence predicates there")
    far = None                                  # horizon H = max(20000, 10n)
    if p["tends_to"] is None and (p["bounded"] or p["limit"] is not None):
        far = generate(row["gen"], max(20000, 10 * row["n"]))
    out = {}
    for n in row["checkpoints"]:
        rule = _rules(row, cert, xs, far, n)
        if xs[n] != xs[n]:
            rule.update({(q, scored[q]): (False, NAN_WHY) for q in PREDS})
        entry = lambda q, cls: [cls, rule[(q, cls)][0], cite(q, cls), rule[(q, cls)][1]]
        v = {q: entry(q, scored[q]) for q in PREDS}
        v.update({col: entry(q, cls) for (q, cls), col in reported.items()})
        out[f"{row['id']}@{n}"] = v
    return out


def postconditions(labels, scored, reported):
    """The derivation's own invariants, checked on its output: every
    predicate has ONE entry, of its scored class (so no verdict is scored
    against two questions), the reported columns are present, and CONVENTION
    converged implies CONVENTION stable (the band is wider than eps)."""
    keys = set(PREDS) | set(reported.values())
    for key, preds in labels.items():
        if set(preds) != keys:
            raise HarnessError(f"{key}: label columns {sorted(preds)}, expected {sorted(keys)}")
        for q in PREDS:
            e = preds[q]
            if len(e) != 4 or e[0] != scored[q] or not isinstance(e[1], bool):
                raise HarnessError(f"{key}.{q}: {e[:2]} is not one {scored[q]} verdict")
        if scored["converged"] == scored["stable"] == "CONVENTION" \
                and preds["converged"][1] and not preds["stable"][1]:
            raise HarnessError(f"{key}: lattice broken: CONVENTION converged without stable")


def derive(corpus, certs):
    defs = {(d["predicate"], d["class"]): d["cite"] for d in corpus["definitions"]}
    scored, reported = scored_classes(corpus)
    labels = {}
    for row in corpus["rows"]:
        labels.update(derive_row(row, certs[row["id"]], defs, scored, reported))
    postconditions(labels, scored, reported)
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
