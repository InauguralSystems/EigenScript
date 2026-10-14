#!/usr/bin/env python3
"""Derive the observer oracle's labels from the corpus (#1746).

usage: derive.py [--corpus PATH] [--write]   (prints, or rewrites the
       labels.json beside the corpus; certificate.json is read from there)

The corpus states, per row, a generator (gen.py) and ONE property set
(limit, tends_to, bounded, deterministic; a random-process row adds the
NIST flags, which must equal the ones its process kind implies) with its
justification. certify.py (offline, sympy) certifies the properties into
certificate.json, keyed by the row (its capability included) and by the
sha256 of gen.py, certify.py and the tolerances certify.py reads from here;
derive refuses a missing or stale certificate and needs no sympy. A row's
`capability` is DERIVED from the values it feeds the runtime (ieee: one is
inf or NaN; int64: an int a double cannot hold exactly) and the declared tag
must equal it. Each predicate is scored against ONE question: its single
scored definition in the corpus `definitions` table, with one exception
recorded there: at a checkpoint whose x_n is NaN every predicate answers
the #1758 NaN convention (false, CONVENTION). A `reported` definition (MATH
"has a limit") becomes a label column that is printed, never scored. Every
row declares `regime`, the index where its generator's law last changes (at
least the structural one: a `pieces` row's last piece, the largest
step(n, c) threshold; any other spelling of step is refused, rule 186). A
MATH verdict read before it is REPORTED, not scored: it would be decided by
values after the read. A CONVENTION verdict there must be decided by
x_0..x_n alone, or the row is refused. Every label is computed here from the
certified properties, the generated values and that table; nothing per
predicate or checkpoint is written by hand. derive() asserts its
postconditions (one entry per predicate, of its scored class, the NaN class
or REPORTED as above; CONVENTION converged implies stable), and score.py
refuses a labels.json that differs from derive(corpus).
"""
import hashlib
import json
import math
import os
import re
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
GEN_KEYS = {"affine": ("x0", "a", "b"), "pieces": ("pieces",), "closed": ("expr",), "recur": ("x0", "expr"),
            "cycle": ("values",), "noise": ("center", "amp", "seed"), "walk": ("x0", "step", "seed")}
STEP = re.compile(r"\bstep\(\s*n\s*,\s*(\d+)\s*\)")      # the one spelling of a law change
NAN_WHY = ("x_n is NaN: the #1758 O2 convention (#1746: NaN is undefined), not a MATH answer:"
           " every predicate is false while the current value is NaN")


def eps(v):
    return RTOL * max(abs(v), SCALE)


def band(v):
    return BAND * max(abs(v), SCALE)


def code_hash():
    """The code that gives a row its meaning: the generator, the certifier and
    the tolerances the certifier reads from here (refute's eps)."""
    h = hashlib.sha256()
    for name in ("gen.py", "certify.py"):
        with open(os.path.join(HERE, name), "rb") as f:
            h.update(f.read())
    h.update(json.dumps({"RTOL": RTOL, "SCALE": SCALE}).encode())
    return h.hexdigest()


def row_hash(row, code):
    """What a certificate vouches for: the generator, the stated properties,
    any manual argument, where the row is read (checkpoints, regime), the
    capability it runs under, and the code that reads them."""
    basis = {k: row.get(k) for k in ("gen", "props", "manual", "checkpoints", "regime", "capability")}
    return hashlib.sha256((json.dumps(basis, sort_keys=True) + code).encode()).hexdigest()


def step_thresholds(expr):
    """The thresholds c of the law changes step(n, c) in an expression. Any
    other spelling of step (step(n, 100.0), step(n - 1, 99), step(n, 50 + 50)
    ...) is REFUSED, never read as no law change (rule 186)."""
    canon = STEP.findall(expr)
    if len(re.findall(r"\bstep\b", expr)) != len(canon):
        raise HarnessError(f"{expr!r}: a law change must be spelled step(n, <integer literal>);"
                           " another spelling would read as no law change (rule 186)")
    return [int(c) for c in canon]


def drop_steps_after(expr, n):
    """The expression with every law change after index n removed (a twin)."""
    step_thresholds(expr)
    return STEP.sub(lambda m: m.group(0) if int(m.group(1)) <= n else "0.0", expr)


def structural_regime(gen):
    """The last index at which the generator's LAW changes: the first value of
    a `pieces` row's last piece, or the largest step(n, c) threshold."""
    if gen["kind"] == "pieces":
        return sum((1 if "x0" in q else 0) + q["steps"] for q in gen["pieces"][:-1])
    if gen["kind"] in ("closed", "recur"):
        return max(step_thresholds(gen["expr"]), default=0)
    return 0


def capability(row):
    """The capability a row NEEDS, from the values it feeds the runtime: ieee
    when one is inf or NaN, int64 when an int is one a double cannot hold
    exactly (some int beyond 2^53), else None."""
    vals = [v for g in [row["gen"]] + ([row["second"]] if "second" in row else []) for v in generate(g, row["n"])]
    if any(isinstance(v, float) and not math.isfinite(v) for v in vals):
        return "ieee"
    if any(isinstance(v, int) and float(v) != v for v in vals):
        return "int64"
    return None


def check_gen(rid, g):
    """The generator's shape, before anything reads it."""
    k = g.get("kind") if isinstance(g, dict) else None
    if k not in GEN_KEYS or any(key not in g for key in GEN_KEYS[k]):
        raise HarnessError(f"{rid}: generator {g!r}: kind must be one of {sorted(GEN_KEYS)} with"
                           f" {GEN_KEYS.get(k, ())}")
    ps = g.get("pieces")
    if k == "pieces" and not (isinstance(ps, list) and ps and all(isinstance(q, dict) and "a" in q and "b" in q
                                                                 for q in ps) and "x0" in ps[0]
                              and all(isinstance(q.get("steps"), int) and q["steps"] > 0 for q in ps[:-1])):
        raise HarnessError(f"{rid}: a pieces row lists pieces with a and b, the first with x0,"
                           " every one but the last with `steps` > 0")
    if k == "cycle" and not (isinstance(g["values"], list) and g["values"]):
        raise HarnessError(f"{rid}: a cycle row lists at least one value")


def scored_classes(corpus):
    """predicate -> its one scored class; reported (predicate, class) -> column.
    The NaN convention (predicate "*") is the recorded exception, not a question."""
    scored, reported = {}, {}
    for d in corpus["definitions"]:
        if d["predicate"] == "*":
            continue
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
        if not s.get("text") or not s.get("status", "").startswith("VERIFIED"):
            raise HarnessError(f"source {k}: needs text and a VERIFIED status that says what was"
                               " checked against which copy (#1754: no unverified citation)")
    for d in c.get("definitions", []):
        if any(s not in sources for s in d["cite"]) or ((d["predicate"], d["class"]) not in RULES
                                                       and (d["predicate"], d["class"]) != ("*", "CONVENTION")):
            raise HarnessError(f"definition {d['predicate']}/{d['class']}: unknown source or no rule")
    if set(scored_classes(c)[0]) != set(PREDS) or sum(d["predicate"] == "*" for d in c["definitions"]) != 1:
        raise HarnessError("every predicate needs exactly one scored definition, and the table one NaN"
                           " convention (predicate \"*\")")
    seen = set()
    for r in rows:
        rid = r.get("id")
        if not rid or rid in seen:
            raise HarnessError(f"row id missing or duplicated: {rid!r}")
        seen.add(rid)
        for k in ("family", "form", "gen", "n", "checkpoints", "regime", "props", "why", "cite"):
            if k not in r:
                raise HarnessError(f"{rid}: missing {k}")
        ats, p, g = r["checkpoints"], r["props"], r["gen"]
        for gg in [g] + ([r["second"]] if "second" in r else []):
            check_gen(rid, gg)
        try:
            sr = structural_regime(g)
        except HarnessError as e:
            raise HarnessError(f"{rid}: {e}")
        if not (isinstance(r["regime"], int) and sr <= r["regime"] <= r["n"]):
            raise HarnessError(f"{rid}: regime {r['regime']!r} must be an index in [{sr},"
                               f" n]: the generator's law last changes at x_{sr}")
        if not ats or ats != sorted(set(ats)) or ats[-1] != r["n"] or ats[0] < 1:
            raise HarnessError(f"{rid}: checkpoints {ats} must be increasing and end at n")
        if any(s not in sources for s in r["cite"]) or not r["why"]:
            raise HarnessError(f"{rid}: properties need a reason and known sources")
        if r.get("capability", "ieee") not in CAPABILITIES:
            raise HarnessError(f"{rid}: unknown capability {r['capability']!r}")
        if r.get("capability") != capability(r):
            raise HarnessError(f"{rid}: capability {r.get('capability')!r} declared, but the values it feeds"
                               f" the runtime need {capability(r)!r} (ieee: an inf or NaN value; int64: an"
                               " int a double cannot hold exactly)")
        if p["limit"] is not None and not (isinstance(p["limit"], (int, float)) and math.isfinite(p["limit"])):
            raise HarnessError(f"{rid}: limit {p['limit']!r}: a limit is a finite number or null")
        if p["tends_to"] not in (None, "+inf", "-inf") or (p["tends_to"] and (p["bounded"] or p["limit"] is not None)):
            raise HarnessError(f"{rid}: tends_to {p['tends_to']!r} excludes a limit and boundedness")
        if p["limit"] is not None and not p["bounded"]:
            raise HarnessError(f"{rid}: a limit implies eventual boundedness")
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
            raise HarnessError(f"{r['id']}: stale certificate (the row, gen.py, certify.py or derive's"
                               " RTOL/SCALE changed since it was certified); re-run certify.py")
        if c.get("kind") not in ("symbolic", "exact", "fixed-point", "ieee", "manual"):
            raise HarnessError(f"{r['id']}: certificate kind {c.get('kind')!r}")
        if r["props"]["deterministic"] and not isinstance(c.get("constant"), bool):
            raise HarnessError(f"{r['id']}: certificate does not decide constancy")
    return certs


def _tail_within(row, far, n, radius, name):
    """CONVENTION converged/stable@n: the tail x_n..x_H stays within
    radius(L) of the limit, or (no limit) fits a ball of radius(centre). A
    tail with an inf or NaN in it is not settled."""
    p = row["props"]
    if far is None:
        return False, "tends to " + p["tends_to"] if p["tends_to"] else "unbounded"
    h, tail = len(far) - 1, far[n:]
    if not all(math.isfinite(v) for v in tail):
        return False, f"x_m is inf or NaN for some m in [{n}, {h}]"
    if p["limit"] is not None:
        lim = p["limit"]
        worst = max(abs(v - lim) for v in tail)
        return worst <= radius(lim), f"max |x_m - {lim:.6g}| over m in [{n}, {h}] = {worst:.3g} vs {name} {radius(lim):.3g}"
    lo, hi = min(tail), max(tail)
    mid = lo / 2 + hi / 2                       # (lo + hi) / 2 overflows near DBL_MAX
    return hi / 2 - lo / 2 <= radius(mid), f"tail x_{n}..x_{h} spans {hi - lo:.3g} vs 2*{name} {2 * radius(mid):.3g}"


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
    return (ok and bounded), why + ("" if bounded else "; not eventually bounded, so not improving"), ok


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
        ("improving", "CONVENTION"): _improving(xs, n, p["bounded"])[:2],
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
    """defs: (predicate, class) -> cite, the NaN convention under predicate "*"."""
    p = row["props"]
    nan_cls, nan_cite = next(((k[1], c) for k, c in defs.items() if k[0] == "*"), (None, None))
    def cite(pred, cls):                        # MATH adds the row's property sources
        base = defs[(pred, cls)]
        return base + [s for s in row["cite"] if s not in base] if cls == "MATH" else base
    xs = generate(row["gen"], row["n"])
    far = None                                  # horizon H = max(20000, 10n)
    if p["tends_to"] is None and (p["bounded"] or p["limit"] is not None):
        far = generate(row["gen"], max(20000, 10 * row["n"]))
    out = {}
    for n in row["checkpoints"]:
        rule = _rules(row, cert, xs, far, n)
        entry = lambda q, cls: [cls, rule[(q, cls)][0], cite(q, cls), rule[(q, cls)][1]]
        if xs[n] == xs[n]:
            v = {q: entry(q, scored[q]) for q in PREDS}
        elif nan_cls is None:
            raise HarnessError(f"{row['id']}@{n}: x_n is NaN and the definitions table has no NaN convention")
        else:                                   # the recorded exception to one question per predicate
            v = {q: [nan_cls, False, list(nan_cite), NAN_WHY] for q in PREDS}
        v.update({col: entry(q, cls) for (q, cls), col in reported.items()})
        if n < row["regime"]:                   # the tail's law starts after this read
            for q in PREDS:
                if v[q][0] == "MATH":
                    v[q][0], v[q][3] = "REPORTED", v[q][3] + (f"; REPORTED, not scored: the law"
                                                             f" changes at x_{row['regime']}, after this read")
                elif not prefix_decided(q, v[q][1], xs, n):
                    raise HarnessError(f"{row['id']}@{n}.{q}: a CONVENTION verdict before the law"
                                       f" changes at x_{row['regime']} depends on later values")
        out[f"{row['id']}@{n}"] = v
    return out


def prefix_decided(q, value, xs, n):
    """Whether x_0..x_n alone decide a CONVENTION verdict: a NaN x_n decides
    every predicate (the NaN convention), settling is refuted by a non-finite
    x_n, and improving by no new best in the window."""
    if xs[n] != xs[n]:
        return value is False
    if q == "improving":
        return not _improving(xs, n, True)[2]
    return value is False and not math.isfinite(xs[n])


def postconditions(labels, scored, reported, rows, nans, nan_cls):
    """The derivation's own invariants, checked on its output: every
    predicate has ONE entry, of its scored class (so no verdict is scored
    against two questions), the NaN class and false at a NaN checkpoint, or
    REPORTED (a MATH verdict read before the row's law last changes); the
    reported columns are present; and CONVENTION converged implies
    CONVENTION stable (the band is wider than eps)."""
    keys = set(PREDS) | set(reported.values())
    for key, preds in labels.items():
        rid, n = key.rsplit("@", 1)
        if set(preds) != keys:
            raise HarnessError(f"{key}: label columns {sorted(preds)}, expected {sorted(keys)}")
        for q in PREDS:
            e = preds[q]
            early = scored[q] == "MATH" and int(n) < rows[rid]["regime"]
            want = nan_cls if key in nans else ("REPORTED" if early else scored[q])
            if len(e) != 4 or e[0] != want or not isinstance(e[1], bool) or (key in nans and e[1]):
                raise HarnessError(f"{key}.{q}: {e[:2]} is not one {want} verdict")
        if scored["converged"] == scored["stable"] == "CONVENTION" \
                and preds["converged"][1] and not preds["stable"][1]:
            raise HarnessError(f"{key}: lattice broken: CONVENTION converged without stable")


def definitions(corpus):
    """(predicate, class) -> cite for every definition, the NaN convention under ("*", class)."""
    return {(d["predicate"], d["class"]): d["cite"] for d in corpus["definitions"]}


def derive(corpus, certs):
    defs = definitions(corpus)
    scored, reported = scored_classes(corpus)
    labels, nans = {}, set()
    for row in corpus["rows"]:
        labels.update(derive_row(row, certs[row["id"]], defs, scored, reported))
        xs = generate(row["gen"], row["n"])
        nans |= {f"{row['id']}@{n}" for n in row["checkpoints"] if xs[n] != xs[n]}
    nan_cls = next(k[1] for k in defs if k[0] == "*")
    postconditions(labels, scored, reported, {r["id"]: r for r in corpus["rows"]}, nans, nan_cls)
    return labels


def dump(labels):
    lines = [f"  {json.dumps(k)}: {json.dumps(v, ensure_ascii=False)}" for k, v in labels.items()]
    return "{\n" + ",\n".join(lines) + "\n}\n"


def main(argv):
    args, path, write = argv[1:], os.path.join(HERE, "corpus.json"), False
    while args:
        if args[0] == "--write":
            write, args = True, args[1:]
        elif args[0] == "--corpus" and len(args) > 1:
            path, args = args[1], args[2:]
        else:
            raise HarnessError(f"usage: derive.py [--corpus PATH] [--write] (not {args[0]!r})")
    cdir = os.path.dirname(os.path.abspath(path))
    corpus = load_corpus(path)
    text = dump(derive(corpus, load_certificates(corpus, os.path.join(cdir, "certificate.json"))))
    if write:
        with open(os.path.join(cdir, "labels.json"), "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except HarnessError as e:
        print(f"OBSERVER_ORACLE_ERROR: {e}", file=sys.stderr)
        sys.exit(2)
    except Exception as e:          # an instrument crash is never a label
        print(f"OBSERVER_ORACLE_ERROR: internal {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(2)
