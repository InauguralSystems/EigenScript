#!/usr/bin/env python3
"""The 16 candidate process families of #1758's Round 3 pre-registration, and
the split (comment 6430031838; RULING R30-4 items 7 and 8).

usage: families.py                      print the H-cal draw, the H1 family list, sha256(families.py)
       families.py --write-hcal         write hcal/corpus.json (the H-cal rows, seeded by S_SPLIT)
       families.py --h1 SEED --out DIR  write DIR/corpus.json: H1 drawn from SEED (the reveal:
                                        SEED = int(drand randomness, 16), see seal.py)

Every row is in corpus.json's schema (derive.load_corpus), so score.py runs
it unchanged and certify.py/derive.py label it. A row's parameters come from
random.Random(sha256("<seed>/<family>/<draw>")), so a row depends only on the
seed, its family and its index. Deterministic families give 8 draws, the
stochastic ones (9, 10, 16) 4 parameter draws x 10 seeds, family 8 its 5 amplitudes x 8 seeds (D8); every row has 3
checkpoints (early, middle, late), each at least its regime index + 10.
"""
import hashlib
import json
import math
import os
import random
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))     # python3 -I drops the script's directory
import derive
import gen

HERE = os.path.dirname(os.path.abspath(__file__))
S_SPLIT = 1600219665266993132
POOL = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16]
H_CAL = random.Random(S_SPLIT).sample(POOL, 4)          # RULING R30-4 item 7, verbatim
HELD = [14, 15]                                          # always held out
H1 = sorted(set(POOL) - set(H_CAL)) + HELD
STOCHASTIC = {8, 9, 10, 16}
RELS = (1e-9, 1e-5, 1e-3, 1e-1, 10.0)                    # family 8's relative amplitudes


def rng(seed, fam, k):
    return random.Random(int.from_bytes(hashlib.sha256(f"{seed}/{fam}/{k}".encode()).digest()[:8], "big"))


def level(r):
    """A nonzero level, log-uniform in [0.1, 100] with a random sign (STOP-3)."""
    return r.choice((-1.0, 1.0)) * 10 ** r.uniform(-1.0, 2.0)


def settle(eps_over_d, rate):
    """Steps until a geometric error |d| rate^n falls below eps."""
    return max(1, math.ceil(math.log(eps_over_d) / math.log(rate)))


def cks(t, base=0):
    """Early, middle, late around a settling time t, each >= base + 10."""
    e = base + max(10, t // 2)
    m = max(e + 1, base + t)
    return [e, m, max(m + 1, base + 2 * t)]


def zeta(p):
    """Riemann zeta by Euler-Maclaurin (N = 20, 5 Bernoulli terms), p > 1."""
    n, b = 20, (1 / 6, -1 / 30, 1 / 42, -1 / 30, 5 / 66)
    s = sum(k ** -p for k in range(1, n)) + n ** (1 - p) / (p - 1) + n ** -p / 2
    fact, rising = 1.0, p
    for j, bj in enumerate(b, 1):
        fact *= (2 * j - 1) * (2 * j)
        s += bj / fact * rising * n ** (-p - 2 * j + 1)
        rising *= (p + 2 * j - 1) * (p + 2 * j)
    return s


def props(limit=None, tends=None, bounded=True, deterministic=True, **flags):
    return {"limit": limit, "tends_to": tends, "bounded": bounded, "deterministic": deterministic, **flags}


def manual(argument, cite, p):
    return {"argument": argument, "cite": cite, "claims": {k: p[k] for k in ("limit", "tends_to", "bounded")}}


IID = ("an iid sequence of a non-degenerate distribution a.s. has |x_{n+1} - x_n| > delta infinitely often,"
       " so it has no limit; it stays within center +- amp")


def row(fam, rid, form, gen, ck, p, why, cite, regime=0, man=None):
    r = {"id": rid, "family": f"F{fam} {NAMES[fam]}", "form": form, "gen": gen, "n": ck[-1], "checkpoints": ck,
         "regime": regime, "props": p, "why": why, "cite": cite}
    if man:
        r["manual"] = man
    cap = derive.capability(r)
    if cap:
        r["capability"] = cap
    return r


def affine_decay(fam, k, r, alternating):
    a = (-1.0 if alternating else 1.0) * r.uniform(0.3, 0.995)
    lim = level(r)
    b = lim * (1.0 - a)
    x0 = lim + r.choice((-1.0, 1.0)) * abs(lim) * r.uniform(0.5, 2.0)
    lim = b / (1.0 - a)
    t = settle(derive.eps(lim) / abs(x0 - lim), abs(a))
    return row(fam, f"f{fam:02d}_{k}", f"x <- {a!r} x + {b!r} from {x0!r}", {"kind": "affine", "x0": x0, "a": a, "b": b},
               cks(t), props(lim), f"|a| < 1: the affine map contracts to b/(1-a) = {lim!r} (Hardy Sec. 72 on a^n)",
               ["HARDY_58", "HARDY_72"])


def f1(k, r): return affine_decay(1, k, r, False)
def f11(k, r): return affine_decay(11, k, r, True)


def f2(k, r):
    p = round(r.uniform(1.05, 3.0), 4)           # exponents to 4 decimals: sympy's limit stalls on long rationals
    return row(2, f"f02_{k}", f"x_n = sum_(k=1)^(n+1) k^-{p!r}", {"kind": "recur", "x0": 1.0, "expr": f"x + 1.0 / (n + 1.0) ** {p!r}"},
               [20, 200, 2000], props(zeta(p)), f"the p-series with p = {p!r} > 1 converges to zeta(p)", ["HARDY_58"])


def power(fam, k, r, lo, hi, ck):
    p, c = round(r.uniform(lo, hi), 4), r.choice((-1.0, 1.0)) * 10 ** r.uniform(-1.0, 1.0)
    return row(fam, f"f{fam:02d}_{k}", f"x_n = {c!r} (n + 1)^{p!r}", {"kind": "closed", "expr": f"{c!r} * (n + 1.0) ** {p!r}"},
               ck, props(None, "+inf" if c > 0 else "-inf", False), f"(n + 1)^p -> +inf for p > 0, scaled by {c!r}", ["HARDY_60"])


def f3(k, r): return power(3, k, r, 0.05, 0.95, [20, 200, 2000])
def f4(k, r): return power(4, k, r, 1.0, 3.0, [20, 100, 500])


def f5(k, r):
    lim = level(r)
    amp, rate, w, ph = abs(lim) * r.uniform(0.5, 2.0), r.uniform(0.8, 0.99), r.uniform(0.3, 2.5), r.uniform(0.0, 2 * math.pi)
    t = settle(derive.eps(lim) / amp, rate)
    return row(5, f"f05_{k}", f"x_n = {lim!r} + {amp!r} {rate!r}^n cos({w!r} n + {ph!r})",
               {"kind": "closed", "expr": f"{lim!r} + {amp!r} * {rate!r} ** n * math.cos({w!r} * n + {ph!r})"},
               cks(t), props(lim), "a decaying envelope times a bounded cosine tends to 0, so x_n tends to the level",
               ["HARDY_58", "HARDY_72"])


def f6(k, r):
    c = level(r)
    amp, per, ph = abs(c) * r.uniform(0.05, 1.0), r.uniform(2.5, 40.0), r.uniform(0.0, 2 * math.pi)
    th, q = 2 * math.pi / per, math.ceil(per)
    p = props()
    arg = (f"theta = 2 pi / P with P = {per!r} > 2 lies in (0, pi), so sin(theta) != 0. If s_n = sin(theta n + phi) -> l,"
           " then c_n = cos(theta n + phi) = (s_{n+1} - s_n cos theta) / sin theta -> m, and s_{n+1} = s_n cos theta +"
           " c_n sin theta, c_{n+1} = c_n cos theta - s_n sin theta give m (1 - cos theta) = -l sin theta and"
           " m sin theta = l (1 - cos theta), whence l = m = 0 (the determinant is 2 - 2 cos theta > 0), contradicting"
           " s_n^2 + c_n^2 = 1: no limit; |x_n - c| <= amp, so bounded (Hardy Sec. 62)")
    return row(6, f"f06_{k}", f"x_n = {c!r} + {amp!r} sin(2 pi n / {per!r} + {ph!r})",
               {"kind": "closed", "expr": f"{c!r} + {amp!r} * math.sin({th!r} * n + {ph!r})"},
               [10 + q, 10 + 3 * q, 10 + 7 * q], p, "a sampled sinusoid of period P > 2 oscillates finitely",
               ["HARDY_62"], man=manual(arg, ["HARDY_62"], p))


def f7(k, r):
    per, c = r.choice((3, 5, 6, 7, 8, 12)), level(r)
    vals = [c + abs(c) * r.uniform(-1.0, 1.0) for _ in range(per)]
    return row(7, f"f07_{k}", f"a period-{per} cycle", {"kind": "cycle", "values": vals},
               [per + 10, 3 * per + 10, 6 * per + 20], props(), "a continual repetition of a cycle of values", ["HARDY_62"])


def f8(k, s, r, rs):
    c, rel = level(r), RELS[k]                              # D8: the five draws ARE the five amplitudes
    p = props(deterministic=False, has_trend=False, periodic=False, variance_changes=False)
    return row(8, f"f08_{k}_{s}", f"iid uniform noise, amplitude {rel!r} |c| about c = {c!r}",
               {"kind": "noise", "center": c, "amp": rel * abs(c), "seed": rs}, [50, 150, 300], p,
               "iid uniform noise: a.s. no limit (second Borel-Cantelli), bounded, stationary", ["BOREL_CANTELLI", "NIST_6442"],
               man=manual(IID, ["BOREL_CANTELLI"], p))


def f9(k, s, r, rs):
    mu, phi = level(r), r.uniform(-0.9, 0.9)
    sig = abs(mu) * 10 ** r.uniform(-3.0, -1.0)
    p = props(deterministic=False, has_trend=False, periodic=False, variance_changes=False)
    arg = (f"|x_n - mu| <= sigma / (1 - |phi|) for all n, so bounded; if x_n -> l then u_n = (x_{{n+1}} - mu -"
           " phi (x_n - mu)) / sigma would converge, but iid non-degenerate u_n a.s. do not (second Borel-Cantelli)")
    return row(9, f"f09_{k}_{s}", f"AR(1) phi = {phi!r} about mu = {mu!r}, uniform innovations of half-width {sig!r}",
               {"kind": "ar1", "mu": mu, "phi": phi, "sigma": sig, "burn": 200, "seed": rs}, [50, 150, 300], p,
               "a stationary AR(1): bounded, no limit, no trend, constant variance", ["BOREL_CANTELLI", "NIST_6442"],
               man=manual(arg, ["BOREL_CANTELLI"], p))


def f10(k, s, r, rs):
    x0 = level(r)
    step = abs(x0) * 10 ** r.uniform(-3.0, -1.0)
    p = props(bounded=False, deterministic=False, has_trend=False, periodic=False, variance_changes=True)
    arg = ("a mean-zero walk with iid non-degenerate bounded steps is recurrent (Chung-Fuchs; the +-1 case is"
           " RW_RECURRENT): it a.s. neither converges nor tends to +-inf, and it is unbounded")
    return row(10, f"f10_{k}_{s}", f"random walk from {x0!r}, steps uniform in +-{step!r}",
               {"kind": "uwalk", "x0": x0, "step": step, "seed": rs}, [50, 150, 300], p,
               "a uniform-step random walk: no limit, not +-inf, variance n step^2/3 grows", ["RW_RECURRENT", "NIST_6442"],
               man=manual(arg, ["RW_RECURRENT"], p))


def f12(k, r):
    p, c = round(r.uniform(0.5, 2.0), 4), r.uniform(1.0, 10.0)
    return row(12, f"f12_{k}", f"x_n = (n + 1)^{p!r} + {c!r} (-1)^n",
               {"kind": "closed", "expr": f"(n + 1.0) ** {p!r} + {c!r} * (-1.0) ** n"}, [20, 100, 500],
               props(None, "+inf", False), "(n+1)^p -> +inf by steps forwards and backwards: diverges, does not oscillate",
               ["HARDY_60", "HARDY_XXIV5"])


def f13(k, r):
    a, lim = r.uniform(0.3, 0.95), level(r)
    b = lim * (1.0 - a)
    x0 = lim + r.choice((-1.0, 1.0)) * abs(lim) * r.uniform(0.5, 2.0)
    kick = lim + r.choice((-1.0, 1.0)) * abs(lim) * r.uniform(0.5, 5.0)
    lim = b / (1.0 - a)
    t = settle(derive.eps(lim) / max(abs(x0 - lim), abs(kick - lim)), a)
    s1 = 2 * t + 10
    gen = {"kind": "pieces", "pieces": [{"x0": x0, "a": a, "b": b, "steps": s1}, {"x0": kick, "a": a, "b": b}]}
    reg = derive.structural_regime(gen)
    return row(13, f"f13_{k}", f"settle on {lim!r} from {x0!r}, kick to {kick!r} at x_{reg}, resettle", gen,
               cks(t, reg), props(lim), "after the kick the same contraction (|a| < 1) resettles on b/(1-a)",
               ["HARDY_58", "HARDY_72"], regime=reg)


def f14(k, r):
    x0, is_int = [1e6, 2.0 ** 40, 2.0 ** 50, 2.0 ** 53][k % 4], k >= 4
    gen = ({"kind": "affine", "x0": int(x0), "a": 1, "b": 1, "int": True} if is_int else
           {"kind": "affine", "x0": x0, "a": 1.0, "b": 2.0 if x0 == 2.0 ** 53 else 1.0})
    return row(14, f"f14_{k}", f"{'int64' if is_int else 'float'} counter from {x0!r} by {gen['b']}", gen, [10, 60, 200],
               props(None, "+inf", False), "a counter tends to +inf (Hardy Sec. 60)", ["HARDY_60"])


def scaled(base, s):
    g, p = json.loads(json.dumps(base["gen"])), dict(base["props"])
    k = g["kind"]
    if k == "affine":
        g["x0"], g["b"] = g["x0"] * s, g["b"] * s
    elif k == "pieces":
        for q in g["pieces"]:
            q["b"] *= s
            if "x0" in q:
                q["x0"] *= s
    elif k == "closed":
        g["expr"] = f"{s!r} * ({g['expr']})"
    elif k == "recur":
        g["x0"], g["expr"] = g["x0"] * s, f"{s!r} * ({__import__('re').sub(r'(?<![A-Za-z_.])x(?![A-Za-z_])', f'(x / {s!r})', g['expr'])})"
    elif k == "cycle":
        g["values"] = [v * s for v in g["values"]]
    elif k == "noise":
        g["center"], g["amp"] = g["center"] * s, g["amp"] * s
    elif k in ("walk", "uwalk"):
        g["x0"], g["step"] = g["x0"] * s, g["step"] * s
    elif k == "ar1":
        g["mu"], g["sigma"] = g["mu"] * s, g["sigma"] * s
    if p["limit"] is not None:
        p["limit"] = p["limit"] * s
    r = {k2: v for k2, v in base.items() if k2 not in ("capability", "manual")}
    r.update({"id": f"f15_{base['id']}_x{s:g}", "family": f"F15 {NAMES[15]}", "gen": g, "props": p, "base": base["id"], "scale": s,
              "form": f"{s:g} x ({base['form']})", "why": f"{base['why']}; scaled by {s:g} > 0, which keeps a limit, +-inf and boundedness"})
    if "manual" in base:
        r["manual"] = manual(base["manual"]["argument"] + f"; the row is the base row times {s:g} > 0", base["manual"]["cite"], p)
    elif base["family"].startswith("F2 "):      # sympy 1.14 sums 1/(n+1)^p but not c/(n+1)^p (STOP-9)
        r["manual"] = manual(f"x_n = {s:g} sum_(k=1)^(n+1) k^-p with p > 1: the p-series converges to zeta(p) (the base"
                             f" row's symbolic certificate), so x_n tends to {s:g} zeta(p)", ["HARDY_58"], p)
    cap = derive.capability(r)
    if cap:
        r["capability"] = cap
    return r


NAMES = {1: "geometric decay to a nonzero limit", 2: "p-series partial sums", 3: "power-law divergence",
         4: "polynomial runaway", 5: "damped sinusoid", 6: "sampled sinusoid", 7: "period-k cycles",
         8: "iid uniform noise", 9: "AR(1), uniform innovations", 10: "random walk, uniform steps",
         11: "alternating contraction", 12: "alternating runaway", 13: "settle, kick, resettle",
         14: "large-magnitude counters", 15: "unit-scaled copies", 16: "modulated decays and runaways (#1891)"}
DET = {1: f1, 2: f2, 3: f3, 4: f4, 5: f5, 6: f6, 7: f7, 11: f11, 12: f12, 13: f13, 14: f14}


def f16(k, s, r, rs):
    g, m, w = r.uniform(0.85, 0.99), r.uniform(0.3, 0.95), r.uniform(0.5, 3.0)
    q = random.Random(rs)
    c, ph = level(q), q.uniform(0.0, 2 * math.pi)
    if k % 2 == 0:
        lim = c * (g / (1.0 - g) + m * (g * math.cos(w + ph) - g * g * math.cos(ph)) / (1.0 - 2.0 * g * math.cos(w) + g * g))
        expr = (f"{c!r} * ({g!r} * (1.0 - {g!r} ** n) / (1.0 - {g!r}) + {m!r} * ({g!r} * math.cos({w!r} + {ph!r})"
                f" - {g!r} ** 2 * math.cos({ph!r}) - {g!r} ** (n + 1) * math.cos({w!r} * (n + 1) + {ph!r})"
                f" + {g!r} ** (n + 2) * math.cos({w!r} * n + {ph!r})) / (1.0 - 2.0 * {g!r} * math.cos({w!r}) + {g!r} ** 2))")
        t = settle(derive.eps(lim) * (1.0 - g) / (abs(c) * (1.0 + m)), g)
        return row(16, f"f16_{k}_{s}", f"x_n = {c!r} sum_(k=1)^n {g!r}^k (1 + {m!r} cos({w!r} k + {ph!r}))",
                   {"kind": "closed", "expr": expr}, cks(t), props(lim),
                   "both geometric series (plain and cosine-weighted) converge absolutely since g < 1", ["HARDY_58", "HARDY_72"])
    expr = f"{c!r} * (n + {m!r} * math.sin({w!r} * n / 2.0) * math.cos({w!r} * (n + 1) / 2.0 + {ph!r}) / math.sin({w!r} / 2.0))"
    return row(16, f"f16_{k}_{s}", f"x_n = {c!r} sum_(k=1)^n (1 + {m!r} cos({w!r} k + {ph!r}))", {"kind": "closed", "expr": expr},
               [10, 60, 200], props(None, "+inf" if c > 0 else "-inf", False),
               f"every step is at least 1 - m = {1 - m:.3g} > 0 in units of c, so x_n -> sign(c) inf", ["HARDY_60"])


RAND = {8: f8, 9: f9, 10: f10, 16: f16}


BASE_MIN, UNIT_FLOOR = 10.0, 1e-2      # D7: a base stays >= 10 in magnitude, so its x1e-3 copy clears 1e-2


def above_floor(values):
    """Decision rule 5's floor: every value at least 1e-2 in magnitude (the x1e-3 copy). judge.py calls this."""
    return all(abs(v) >= UNIT_FLOOR for v in values)


def eligible_base(row):
    """D7: a family-15 base keeps |x| >= 10 over its whole run, and its x1e-3 copy clears the floor."""
    return all(abs(v) >= BASE_MIN for v in gen.generate(row["gen"], row["n"])) and \
        above_floor(gen.generate(scaled(row, 1e-3)["gen"], row["n"]))


def f15_bases(seed):
    """D7: ten base rows drawn from the other H1 families' own generators, each kept only if it stays >= 10 in
    magnitude over its whole run (its x1e-3 copy then clears the floor); the draw is a deterministic rejection
    sampler over sub-seeds, and a base that never comes is refused. A pool of existing rows did not suffice:
    on 11 of seeds 1-500 it held fewer than 10 such rows."""
    fams, out = sorted(f for f in H1 if f not in (14, 15)), []
    for attempt in range(5000):
        r = rng(seed, 15, f"base/{attempt}")
        fam = r.choice(fams)
        row = (RAND[fam](r.randrange(len(RELS) if fam == 8 else 4), 0, r, r.randrange(2 ** 31)) if fam in STOCHASTIC
               else DET[fam](r.randrange(8), r))
        if eligible_base(row):
            row.update({"id": f"f15b_{len(out)}", "family": f"F15b base for unit-scaled copies, from F{fam} {NAMES[fam]}"})
            out.append(row)
            if len(out) == 10:
                return out
    raise gen.HarnessError(f"family 15, seed {seed}: fewer than 10 bases with |x| >= {BASE_MIN} in 5000 draws: refused")


def family_rows(fam, seed, pool_rows=()):
    if fam == 15:
        bases = f15_bases(seed)
        rows = [scaled(b, s) for b in bases for s in (1e-3, 1e3)]
        assert all(eligible_base(b) for b in bases) and all(above_floor(gen.generate(c["gen"], c["n"])) for c in rows if c["scale"] < 1)
        return bases + rows
    if fam in STOCHASTIC:
        out = []
        for k in range(len(RELS) if fam == 8 else 4):           # D8: family 8 is 5 amplitudes x 8 seeds
            r = rng(seed, fam, k)
            st = r.getstate()
            for s in range(8 if fam == 8 else 10):
                r.setstate(st)                       # every seed sees the same parameter draw
                rs = rng(seed, fam, f"{k}/seed{s}").randrange(2 ** 31)
                out.append(RAND[fam](k, s, r, rs))
        return out
    return [DET[fam](k, rng(seed, fam, k)) for k in range(8)]


def build(fams, seed):
    rows = []
    for f in sorted(x for x in fams if x != 15):
        rows += family_rows(f, seed)
    if 15 in fams:
        rows += family_rows(15, seed, rows)
    with open(os.path.join(HERE, "corpus.json")) as f:
        main = json.load(f)
    return {"note": f"#1758 Round 3 families {sorted(fams)}, seed {seed}; generated by families.py sha256 {sha()}",
            "sources": main["sources"], "definitions": main["definitions"], "rows": rows}


def sha(path=None):
    with open(path or os.path.abspath(__file__), "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


# The reveal-path manifest (RULING R30I-2 item 5, R30I-3 items 2-3): a corpus directory is scored only against the
# code, labels and arms it was sealed with. families.py/seal.py write it at generation (labels pending); judge.py
# --write-manifest completes it after certify/derive; judge.py --corpus DIR refuses any mismatch (exit 2). The
# manifest's own sha256 is printed at sealing and at verification: it is the number posted on #1758.
MANIFEST, SET = "manifest.json", ("corpus.json", "labels.json", "certificate.json")
TOOLS = os.path.dirname(HERE)                       # tools/: native_witness.py lives here (R30I-4 item 4)


def load_json(path):
    with open(path) as f:
        return json.load(f)


_CODE = []


def measurement_code():
    """The code that can change a reading, DERIVED (R30I-4 item 4, mechanical-gates section 1): every file under
    tools/ that `import judge, score, plants` loads, read from sys.modules in a fresh `python3 -I` (so the
    calling process's own imports cannot widen or narrow it). No hand list; refused if empty."""
    if not _CODE:
        code = ("import json, sys; sys.path.insert(0, sys.argv[1]); import judge, score, plants; print(json.dumps(sorted("
                "m.__file__ for m in list(sys.modules.values()) if getattr(m, '__file__', None)"
                " and m.__file__.startswith(sys.argv[2] + '/'))))")
        out = subprocess.run([sys.executable, "-I", "-c", code, HERE, TOOLS], capture_output=True, text=True, check=True)
        _CODE.extend(os.path.relpath(f, TOOLS) for f in json.loads(out.stdout))
        if not _CODE or "observer_oracle/judge.py" not in _CODE:
            raise gen.HarnessError(f"the derived measurement code list is {_CODE}: refused (it must hold judge.py and its imports)")
    return list(_CODE)


def tree_sha(d):
    """sha256 over (relative path, sha256) of every file under d, sorted."""
    h = hashlib.sha256()
    for root, dirs, files in os.walk(d):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(root, f)
            h.update(f"{os.path.relpath(p, d)}\0{sha(p)}\n".encode())
    return h.hexdigest()


def arm_root(binary):
    """The tree an arm binary was built in (the nearest ancestor with a Makefile and lib/): its stdlib."""
    d = os.path.dirname(os.path.realpath(binary))
    for _ in range(4):
        if os.path.isfile(os.path.join(d, "Makefile")) and os.path.isdir(os.path.join(d, "lib")):
            return d
        d = os.path.dirname(d)
    return None


def arm_record(binary):
    """D10: an arm is (source_sha, recipe_id) from the stamp its recipe wrote beside it (build_arm.sh's arm.json,
    build_anchor.sh's anchor.json). binary_sha256 is the executable now; stamp_binary_sha256 is what the recipe built,
    and the two must be equal (R30I-4 item 3). lib is the tree hash of the arm's stdlib directory (item 4). A binary
    with no stamp records only its sha256 and lib."""
    real, d = os.path.realpath(binary), os.path.dirname(os.path.realpath(binary))
    root = arm_root(binary)
    rec = {"source_sha": None, "recipe_id": None, "binary_sha256": sha(binary), "stamp_binary_sha256": None,
           "lib": tree_sha(os.path.join(root, "lib")) if root else None}
    for _ in range(4):
        for stamp, src, rid in (("arm.json", "source_sha", "recipe_id"), ("anchor.json", "commit", "recipe_sha256")):
            path = os.path.join(d, stamp)
            if os.path.exists(path):
                st = load_json(path)
                if os.path.realpath(st.get("binary", "")) == real:
                    rec.update(source_sha=st[src], recipe_id=st[rid], stamp_binary_sha256=st.get("binary_sha256"))
                    return rec
        d = os.path.dirname(d)
    return rec


def programs_sha(d):
    """sha256 of every program score.py runs for the set's rows (each row's straight form and each loop form)."""
    import score
    h = hashlib.sha256()
    for row in load_json(os.path.join(d, "corpus.json"))["rows"]:
        xs = gen.generate(row["gen"], row["n"])
        ys = gen.generate(row["second"], row["n"]) if "second" in row else None
        h.update(score.emit_straight(row, xs, ys).encode())
        for c in row["checkpoints"]:
            for warm in sorted({a["warmup"] for a in score.ARMS.values()}):
                h.update(score.emit_loop(row, xs, ys, c, warm).encode())
    return h.hexdigest()


def manifest_of(d, arms):
    have = {f: (sha(os.path.join(d, f)) if os.path.exists(os.path.join(d, f)) else None) for f in SET}
    return {"format": "r3-manifest/3", "set": have,
            "programs": programs_sha(d) if have["corpus.json"] else None,
            "code": {f: sha(os.path.join(TOOLS, f)) for f in measurement_code()},
            "arms": {a: arm_record(b) for a, b in sorted(arms.items())}}


def write_manifest(d, arms):
    """Write d/manifest.json; an existing manifest's code and corpus.json pins must still hold (no re-sealing over a
    change), and a recipe arm must be the binary its stamp records. Prints the manifest's sha256."""
    m, path = manifest_of(d, arms), os.path.join(d, MANIFEST)
    stale = [a for a, r in m["arms"].items() if r["recipe_id"] and r["binary_sha256"] != r["stamp_binary_sha256"]]
    if stale:
        raise gen.HarnessError(f"{path}: arm(s) {stale} are not the binary their recipe stamp records: refused")
    if os.path.exists(path):
        old = load_json(path)
        if old.get("code") != m["code"] or old["set"].get("corpus.json") != m["set"]["corpus.json"]:
            raise gen.HarnessError(f"{path}: the code or corpus.json changed since this set was sealed: refused")
    with open(path, "w") as f:
        json.dump(m, f, indent=1, sort_keys=True)
        f.write("\n")
    print(f"manifest sealed: {path} sha256 {sha(path)} ({len(m['code'])} code files derived from the import graph)")
    return m


def verify_manifest(d, arms):
    """HarnessError (exit 2, never a verdict) unless d/manifest.json pins exactly this set, its row programs, the
    derived measurement code and every arm: a recipe arm by (source_sha, recipe_id) AND its binary equal to its own
    stamp's binary_sha256 (the sealed binary sha256 is information: another machine builds other bytes), an arm with
    no recipe by its binary sha256; every arm's stdlib tree."""
    path = os.path.join(d, MANIFEST)
    try:
        want = load_json(path)
    except (OSError, ValueError) as e:
        raise gen.HarnessError(f"{path}: no readable manifest ({e}); seal the set with judge.py --write-manifest")
    have = manifest_of(d, arms)
    bad = [f"{k}/{f}" for k in ("set", "code") for f in sorted(set(have[k]) | set(want.get(k, {})))
           if want.get(k, {}).get(f) is None or want[k][f] != have[k].get(f)]
    bad += ["programs"] if want.get("programs") != have["programs"] else []
    info = []
    for a, h in have["arms"].items():
        w = want.get("arms", {}).get(a)
        if not isinstance(w, dict):
            bad.append(f"arms/{a}")
            continue
        if w.get("lib") != h["lib"]:
            bad.append(f"arms/{a} (stdlib tree)")
        if w.get("recipe_id") is None:
            bad += [f"arms/{a} (no recipe: binary sha256)"] if w.get("binary_sha256") != h["binary_sha256"] else []
        elif (w.get("source_sha"), w.get("recipe_id")) != (h["source_sha"], h["recipe_id"]):
            bad.append(f"arms/{a} (source {h['source_sha']} recipe {str(h['recipe_id'])[:12]}, sealed source"
                       f" {w.get('source_sha')} recipe {str(w.get('recipe_id'))[:12]})")
        elif h["binary_sha256"] != h["stamp_binary_sha256"]:
            bad.append(f"arms/{a} (the executable {h['binary_sha256'][:12]} is not the binary its stamp records,"
                       f" {str(h['stamp_binary_sha256'])[:12]})")
        else:
            info.append(f"{a}: source {h['source_sha'][:12]} recipe {h['recipe_id'][:12]} binary {h['binary_sha256'][:12]}"
                        + (" (as sealed)" if h["binary_sha256"] == w.get("binary_sha256") else
                           f" (sealed binary {str(w.get('binary_sha256'))[:12]}: another toolchain, information only)"))
    if bad:
        raise gen.HarnessError(f"{path}: {', '.join(bad)} differ from (or are missing in) the manifest: refused")
    print(f"manifest verified: {path} sha256 {sha(path)} ({len(have['code'])} code files derived from the import graph)"
          + "".join(f"\n  arm {x}" for x in info))


def write(corpus, d):
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "corpus.json"), "w") as f:
        f.write("{\n" + ",\n".join(f" {json.dumps(k)}: {json.dumps(v)}" for k, v in corpus.items() if k != "rows")
                + ',\n "rows": [\n' + ",\n".join("  " + json.dumps(r) for r in corpus["rows"]) + "\n ]\n}\n")


def summary():
    print(f"python {sys.version.split()[0]}; S_split = {S_SPLIT}")
    print(f"H-cal = random.Random(S_split).sample({POOL}, 4) = {H_CAL}: " + ", ".join(f"{f} {NAMES[f]}" for f in H_CAL))
    print(f"H1 families ({len(H1)}): " + ", ".join(f"{f} {NAMES[f]}" for f in H1))
    print(f"sha256(families.py) = {sha()}")


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        summary()
    elif args == ["--write-hcal"]:
        summary()
        c = build(H_CAL, S_SPLIT)
        write(c, os.path.join(HERE, "hcal"))
        print(f"H-cal: {len(c['rows'])} rows, {sum(len(r['checkpoints']) for r in c['rows'])} checkpoints -> hcal/corpus.json")
    elif len(args) == 4 and args[0] == "--h1" and args[2] == "--out":
        c = build(H1, int(args[1]))
        write(c, args[3])
        write_manifest(args[3], {})
        print(f"H1 (seed {args[1]}): {len(c['rows'])} rows, {sum(len(r['checkpoints']) for r in c['rows'])} checkpoints -> {args[3]}")
    else:
        sys.exit(__doc__)
