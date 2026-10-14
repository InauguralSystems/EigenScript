#!/usr/bin/env python3
"""Certify the observer oracle corpus' mathematical properties (#1746).

usage: ~/.local/venvs/oracle/bin/python certify.py [--corpus PATH]

OFFLINE: needs sympy, which the scorer and the build never import. For every
row it decides, from the row's generator, whether the stated `limit`,
`tends_to` and `bounded` are TRUE, and whether the sequence is constant, and
writes certificate.json (beside the corpus) with the sha256 of each row's
generator and properties (derive.row_hash). derive.py refuses a missing or
stale certificate. Kinds:
  symbolic     sympy decides it: closed forms (sympy.limit over a real
               variable, which is sound for the integer sequence when the
               result is a number or +-oo; an AccumBounds result also needs
               the integer samples to span half the bounds), affine
               recurrences (their exact closed form) and x <- x + g(n) (a
               series sum)
  exact        a cycle of literal values: it converges iff it is constant
  fixed-point  x <- f(x) with limit L: f(L) = L, |f'| < 1 on an interval I
               around L (bounded with sympy), and the iterates enter I
  manual       sympy cannot decide it: the row's `manual` block carries a
               citation and a one-line argument; counted and printed
Exit 0 and write the file only when every row is certified; exit 1 listing
every refusal otherwise.
"""
import json
import os
import signal
import sys

import sympy as sp
from sympy.calculus.util import maximum, minimum

import derive

N = sp.Symbol("n", integer=True, nonnegative=True)
T = sp.Symbol("t", positive=True)               # real-variable stand-in for n
X = sp.Symbol("x", real=True)
I = sp.Symbol("i", integer=True, positive=True)
# step(n, c) is 1 for n >= c, else 0: the same text means the same integer
# sequence in the generator (derive.ENV) and here (Heaviside at c - 1/2).
STEP = sp.Lambda((N, sp.Symbol("c")), sp.Heaviside(N - sp.Symbol("c") + sp.Rational(1, 2)))


class Undecided(Exception):
    pass


def parse(expr, names):
    return sp.sympify(expr.replace("math.", ""), locals={**names, "step": STEP}, rational=True)


def realify(ex):
    """The real function the sequence samples at integers: (-b)**e -> cos(pi e) b**e."""
    ex = ex.subs(N, T)
    return ex.replace(lambda q: q.is_Pow and q.base.is_number and q.base.is_negative,
                      lambda q: sp.cos(sp.pi * q.exp) * (-q.base) ** q.exp)


def close(a, b):
    a = complex(sp.N(a, 30))
    return a.imag == 0 and abs(a.real - float(b)) <= 1e-12 * max(1.0, abs(float(b)))


def limit_of(ex, row):
    """('limit', L) | ('tends', '+inf'|'-inf') | ('bounded-nolimit', lo, hi) | Undecided."""
    lim = sp.limit(realify(ex), T, sp.oo)
    if lim is sp.oo or lim is sp.S.NegativeInfinity:
        return ("tends", "+inf" if lim is sp.oo else "-inf")
    if isinstance(lim, sp.AccumBounds):
        lo, hi = lim.min, lim.max
        if not (lo.is_finite and hi.is_finite):
            raise Undecided(f"sympy: {lim}")
        far = derive.generate(row["gen"], max(20000, 10 * row["n"]))
        tail = far[len(far) // 2:]
        if max(tail) - min(tail) < float(hi - lo) / 2:   # real-variable bound, integer witness
            raise Undecided(f"sympy bounds real n by {lim}, but the integer samples span only"
                            f" {max(tail) - min(tail):.3g}")
        return ("bounded-nolimit", float(lo), float(hi))
    if lim.is_number and lim.is_finite and lim.is_real:
        return ("limit", lim)
    raise Undecided(f"sympy: {lim}")


def agree(ex, row):
    """The parsed form must be the generator over the observed indices."""
    f = derive._fn(row["gen"])
    for k in range(0, min(row["n"], 200) + 1):
        want, got = float(f(k)), complex(sp.N(ex.subs(N, k), 20))
        if got.imag != 0 or abs(got.real - want) > 1e-9 * max(1.0, abs(want)):
            raise ValueError(f"sympy reads the generator differently at n={k}: {got.real!r} vs {want!r}")


def closed_constant(ex):
    c0 = ex.subs(N, 0)
    if sp.simplify(ex - c0) == 0:
        return True
    for k in list(range(1, 201)) + [10 ** e for e in range(3, 13)]:
        if abs(complex(sp.N(ex.subs(N, k) - c0, 30))) > 1e-20 * max(1.0, abs(complex(sp.N(c0)))):
            return False
    raise Undecided("cannot decide whether it is constant")


def constant(row):
    """Decided from the generator itself, not from a horizon of samples."""
    g = row["gen"]
    k = g["kind"]
    if k in derive.RANDOM_KINDS:
        return None
    if k == "cycle":
        return len(set(g["values"])) == 1
    if k == "closed":
        return closed_constant(parse(g["expr"], {"n": N}))
    x0 = sp.Rational(repr(g["x0"]))
    if k == "affine":
        a, b = sp.Rational(repr(g["a"])), sp.Rational(repr(g["b"]))
        return a * x0 + b == x0
    f = parse(g["expr"], {"x": X, "n": N})
    if sp.simplify(f.subs({N: 1, X: x0}) - x0) != 0:
        return False                                  # x_1 != x_0
    if N not in f.free_symbols or sp.simplify(f - X) == 0:
        return True                                   # a fixed point from the start
    raise Undecided("cannot decide whether it is constant")


def fixed_point(f, row, lim):
    """f(L) = L; a sympy-bounded contraction on I = [L-d, L+d]; iterates enter I."""
    exact = sp.simplify(f.subs(X, sp.nsimplify(lim)) - sp.nsimplify(lim)) == 0
    if not exact and not close(f.subs(X, sp.Float(lim, 30)) - sp.Float(lim, 30), 0.0):
        raise ValueError(f"f(L) != L at the stated limit {lim}")
    fp, lq = sp.diff(f, X), sp.Rational(lim)
    d = sp.Rational(max(abs(lim), 1.0)) / 2
    for _ in range(30):
        iv = sp.Interval(lq - d, lq + d)
        q = max(abs(maximum(fp, X, iv)), abs(minimum(fp, X, iv)))
        if q < 1:
            break
        d /= 2
    else:
        raise Undecided("no interval around L on which |f'| < 1")
    xs = derive.generate(row["gen"], max(20000, 10 * row["n"]))
    k = next((i for i, v in enumerate(xs) if abs(v - lim) <= float(d) / 2), None)
    if k is None:
        raise ValueError(f"the iterates never enter I = L +- {float(d):.3g}")
    return (f"f(L) = L {'exactly' if exact else 'to 1e-12'}; max |f'| = {float(q):.4f} < 1 on"
            f" L +- {float(d):.4g}; x_{k} is inside")


def decide(row):
    """(kind, verdict, detail), or raise Undecided / ValueError."""
    g, p = row["gen"], row["props"]
    k = g["kind"]
    if k in derive.RANDOM_KINDS:
        raise Undecided("a realization of a random process")
    if k == "cycle":
        vs = g["values"]
        v = ("limit", vs[0]) if len(set(vs)) == 1 else ("bounded-nolimit", min(vs), max(vs))
        return "exact", v, "a cycle converges iff it is constant"
    if k == "closed":
        ex = parse(g["expr"], {"n": N})
        agree(ex, row)
        return "symbolic", limit_of(ex, row), "sympy.limit"
    if k == "affine":
        a, b, x0 = (sp.Rational(repr(g[v])) for v in ("a", "b", "x0"))
        ex = x0 + b * N if a == 1 else a ** N * (x0 - b / (1 - a)) + b / (1 - a)
        return "symbolic", limit_of(ex, row), "exact closed form of x <- a x + b"
    f = parse(g["expr"], {"x": X, "n": N})
    if N not in f.free_symbols:                       # autonomous x <- f(x)
        if p["limit"] is None:
            raise Undecided("an autonomous recurrence without a stated limit")
        return "fixed-point", ("limit", p["limit"]), fixed_point(f, row, p["limit"])
    gn = sp.simplify(f - X)
    if X in gn.free_symbols:
        raise Undecided("a non-autonomous recurrence that is not x <- x + g(n)")
    s = sp.summation(gn.subs(N, I), (I, 1, sp.oo))
    if isinstance(s, sp.Sum):
        raise Undecided(f"sympy cannot sum {gn}")
    if s is sp.oo or s is sp.S.NegativeInfinity:
        v = ("tends", "+inf" if s is sp.oo else "-inf")
    elif s.is_number and s.is_finite:
        v = ("limit", sp.Rational(repr(g["x0"])) + s)
    else:
        raise Undecided(f"series sum {s}")
    return "symbolic", v, f"x <- x + g(n): x_0 + sum g = {v[1]}"


def matches(v, p):
    if v[0] == "limit":
        return p["limit"] is not None and close(v[1], p["limit"]) and p["bounded"]
    if v[0] == "tends":
        return p["limit"] is None and p["tends_to"] == v[1] and not p["bounded"]
    return p["limit"] is None and p["tends_to"] is None and p["bounded"]


def _alarm(signum, frame):
    raise Undecided("sympy took longer than 120 s")


def certify(corpus):
    sources = corpus["sources"]
    certs, refused = {}, []
    counts = {"symbolic": 0, "exact": 0, "fixed-point": 0, "manual": 0}
    signal.signal(signal.SIGALRM, _alarm)
    for row in corpus["rows"]:
        rid, p, man = row["id"], row["props"], row.get("manual")
        signal.alarm(120)
        try:
            const = constant(row)
            try:
                kind, verdict, detail = decide(row)
            except Undecided as e:
                if not man or not man.get("argument") or not man.get("cite") \
                        or any(s not in sources for s in man["cite"]):
                    raise Undecided(f"{e}; add a manual block with a citation")
                kind, detail = "manual", f"{man['argument']} [{', '.join(man['cite'])}] (undecided by sympy: {e})"
            else:
                if not matches(verdict, p):
                    raise ValueError(f"stated limit={p['limit']} tends_to={p['tends_to']}"
                                     f" bounded={p['bounded']}, but {kind} gives {verdict}")
                if man:
                    raise ValueError(f"manual block unused ({kind} decides it); remove it")
        except (Undecided, ValueError) as e:
            refused.append(f"{rid}: {e}")
            continue
        finally:
            signal.alarm(0)
        counts[kind] += 1
        certs[rid] = {"hash": derive.row_hash(row), "kind": kind, "constant": const, "detail": detail}
        print(f"  {rid:22} {kind:11} constant={const!s:5} {detail}")
    return certs, refused, counts


def main(argv):
    path = argv[2] if argv[1:2] == ["--corpus"] else os.path.join(derive.HERE, "corpus.json")
    corpus = derive.load_corpus(path)
    certs, refused, counts = certify(corpus)
    print("certified: " + ", ".join(f"{k}={v}" for k, v in counts.items())
          + f"; refused={len(refused)} of {len(corpus['rows'])} rows")
    for r in refused:
        print(f"REFUSED {r}")
    if refused or len(certs) != len(corpus["rows"]):
        return 1
    with open(os.path.join(os.path.dirname(os.path.abspath(path)), "certificate.json"), "w") as f:
        f.write("{\n \"sympy\": " + json.dumps(sp.__version__) + ",\n \"rows\": {\n"
                + ",\n".join(f"  {json.dumps(k)}: {json.dumps(v)}" for k, v in certs.items())
                + "\n }\n}\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except derive.HarnessError as e:
        print(f"OBSERVER_ORACLE_ERROR: {e}", file=sys.stderr)
        sys.exit(2)
