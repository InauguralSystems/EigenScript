#!/usr/bin/env python3
"""Certify the observer oracle corpus' mathematical properties (#1746).

usage: ~/.local/venvs/oracle/bin/python certify.py [--corpus PATH]

OFFLINE: needs sympy, which the scorer and the build never import. For every
row it decides, from the row's generator, whether the stated `limit`,
`tends_to` and `bounded` are TRUE, and whether the sequence is constant, and
writes certificate.json beside the corpus (only beside a corpus given with
--corpus; any other argument is a usage error) keyed by the row and by the
sha256 of gen.py, this file and derive's RTOL/SCALE (derive.row_hash):
editing any of them makes every certificate stale. Kinds:
  symbolic     sympy decides it: a closed form (sympy.limit over a real
               variable, which is sound for the integer sequence when the
               result is a number or +-oo; otherwise the even and odd
               subsequences must both have such limits: equal, it is their
               limit; different, there is no limit), an affine recurrence or
               the last piece of a `pieces` row (the exact closed form of the
               map on the floats the runtime is FED: the exact binary values
               of x_s, a and b; on a repelling fixed point, |a| > 1, the
               floats must stay on it exactly, or the row is REFUSED, since
               rounding error grows by |a| per step), or x <- x + g(n) (a
               series sum)
  exact        a cycle of literal values: it converges iff it is constant
  fixed-point  x <- f(x) with a stated limit L: f(L) = L and |f'| < 1 on an
               interval around L (bounded with sympy) that the iterates enter.
               |f'(L)| > 1 (repelling) is REFUSED, manual block or not
  ieee         an in-program row whose value becomes NaN (IEEE 754: inf * 0)
               and never restarts: NaN is absorbing, so the tail is undefined
  manual       none of the above decides it: the row's `manual` block carries
               an argument, a citation and the `claims` it certifies
`bounded` means EVENTUALLY bounded (lim sup |x_n| < inf; #1758 comment
6173870348): finitely many early terms, inf included, never decide it.
Numerics may REFUTE, never prove: whatever decided it, the values the
runtime is fed must be consistent with the verdict (a limit whose error
keeps shrinking toward 0 over a 10^6-term horizon, or is within eps: the
error over the horizon's last tenth must be under RHO = 0.95 of the error
over its last decade; a run to +-inf; a tail that does not settle; finite
late values, in the row and past the first tenth of the horizon, for a
finite limit or `bounded`: an inf there refutes both), or the row is
refused. A manual block cannot
override that, nor any refusal above. Exit 0 and write the file only when
every row is certified; exit 1 listing every refusal; exit 2 on an internal
error (a sympy exception, or a row taking longer than ALARM_S = 120 s,
#1766), which never falls through to `manual`.
"""
import json
import math
import os
import signal
import sys

import sympy as sp
from sympy.calculus.util import maximum, minimum

import derive
import gen

N = sp.Symbol("n", integer=True, nonnegative=True)
K = sp.Symbol("k", integer=True, nonnegative=True)
T = sp.Symbol("t", positive=True)               # real-variable stand-in for n
X = sp.Symbol("x", real=True)
I = sp.Symbol("i", integer=True, positive=True)
# step(n, c) is 1 for n >= c, else 0: the same text means the same integer
# sequence in the generator (gen.ENV) and here (Heaviside at c - 1/2).
STEP = sp.Lambda((N, sp.Symbol("c")), sp.Heaviside(N - sp.Symbol("c") + sp.Rational(1, 2)))


class Undecided(Exception):
    """The automated routes cannot decide the row: a manual block may."""


class Refused(Exception):
    """The row is wrong as stated, whatever its manual block says."""


class SympyTimeout(BaseException):
    """A BaseException, so no `except Exception` inside sympy can swallow it."""


ALARM_S = 120          # per row; a timeout is an internal error (#1766), never `manual`
RHO = 0.95             # a limit is refuted when the error does not shrink by 5% across a decade


def parse(expr, names):
    return sp.sympify(expr.replace("math.", ""), locals={**names, "step": STEP}, rational=True)


def exact(v):
    """The exact value of what the runtime holds: a double's binary value, or an int."""
    return sp.Rational(v) if isinstance(v, float) else sp.Integer(v)


def realify(ex):
    """The real function the sequence samples at integers: (-b)**e -> cos(pi e) b**e."""
    ex = ex.subs({N: T, K: T})
    return ex.replace(lambda q: q.is_Pow and q.base.is_number and q.base.is_negative,
                      lambda q: sp.cos(sp.pi * q.exp) * (-q.base) ** q.exp)


def close(a, b):
    a, b = complex(sp.N(a, 30)), float(b)
    if a.imag != 0:
        return False
    if not (math.isfinite(a.real) and math.isfinite(b)):
        return a.real == b                            # an infinity is close only to itself
    return abs(a.real - b) <= 1e-12 * max(1.0, abs(b))


def limit_of(ex):
    """{limit, tends_to, bounded} of the integer sequence ex(n), or Undecided."""
    def lim(e):
        r = sp.limit(realify(e), T, sp.oo)
        return r if r in (sp.oo, -sp.oo) or (r.is_number and r.is_finite and r.is_real) else None
    whole = lim(ex)
    if whole is not None:
        subs, how = [whole, whole], f"sympy.limit = {whole if whole in (sp.oo, -sp.oo) else sp.N(whole, 12)}"
    else:   # (-b)**(2k + r) = (-1)**r b**(2k + r): parity decides the sign exactly
        split = ex.replace(lambda q: q.is_Pow and q.base.is_number and q.base.is_negative and q.base != -1,
                           lambda q: sp.Pow(-1, q.exp) * (-q.base) ** q.exp)
        subs = [lim(sp.powsimp(sp.expand_power_exp(split.subs(N, 2 * K + r)))) for r in (0, 1)]
        if None in subs:
            raise Undecided(f"sympy decides neither the limit of {ex} nor those of its even and"
                            " odd subsequences (no automatic 'no limit' from AccumBounds)")
        how = f"even/odd subsequences tend to {subs[0]} and {subs[1]}"
    if subs[0] == subs[1]:
        if subs[0] in (sp.oo, -sp.oo):
            return {"limit": None, "tends_to": "+inf" if subs[0] == sp.oo else "-inf", "bounded": False}, how
        return {"limit": subs[0], "tends_to": None, "bounded": True}, how
    return {"limit": None, "tends_to": None, "bounded": all(s.is_finite for s in subs)}, how


def agree(ex, row):
    """The parsed form must be the generator over the observed indices."""
    f = gen.fn(row["gen"])
    for k in range(0, min(row["n"], 200) + 1):
        want, got = float(f(k)), complex(sp.N(ex.subs(N, k), 20))
        if got.imag != 0 or abs(got.real - want) > 1e-9 * max(1.0, abs(want)):
            raise Refused(f"sympy reads the generator differently at n={k}: {got.real!r} vs {want!r}")


def constant(row):
    """Decided from the generator itself, not from a horizon of samples."""
    g = row["gen"]
    k = g["kind"]
    if k in gen.RANDOM_KINDS:
        return None
    if k == "cycle":
        return len(set(g["values"])) == 1
    if k == "closed":
        ex = parse(g["expr"], {"n": N})
        if sp.simplify(ex - ex.subs(N, 0)) == 0:
            return True
        c0 = ex.subs(N, 0)
        for j in list(range(1, 201)) + [10 ** e for e in range(3, 13)]:
            if abs(complex(sp.N(ex.subs(N, j) - c0, 30))) > 1e-20 * max(1.0, abs(complex(sp.N(c0)))):
                return False
        raise Undecided("cannot decide whether it is constant")
    if k in gen.IN_PROGRAM:                           # the float map from the last piece on:
        vals = gen.generate(g, derive.structural_regime(g) + 1)   # x_{s+1} = x_s is a fixed point
        return all(v == vals[0] for v in vals)
    x0, f = sp.Rational(repr(g["x0"])), parse(g["expr"], {"x": X, "n": N})
    if sp.simplify(f.subs({N: 1, X: x0}) - x0) != 0:
        return False                                  # x_1 != x_0
    if N not in f.free_symbols or sp.simplify(f - X) == 0:
        return True                                   # a fixed point from the start
    raise Undecided("cannot decide whether it is constant")


def fixed_point(f, row, lim):
    """f(L) = L; not repelling; a sympy-bounded contraction on I = [L-d, L+d]
    that the iterates enter."""
    L = sp.nsimplify(lim)
    exact = sp.simplify(f.subs(X, L) - L) == 0
    if not exact and not close(f.subs(X, sp.Float(lim, 30)) - sp.Float(lim, 30), 0.0):
        raise Refused(f"f(L) != L at the stated limit {lim}: L is not a fixed point")
    fp = sp.diff(f, X)
    q0 = abs(complex(sp.N(fp.subs(X, L if exact else sp.Float(lim, 30)), 30)))
    if q0 > 1 + 1e-12:
        raise Refused(f"|f'(L)| = {q0:.4g} > 1: L = {lim} is a repelling fixed point, which an"
                      " orbit converges to only by landing on it exactly")
    if q0 >= 1 - 1e-12:
        raise Undecided(f"|f'(L)| = {q0:.4g}: no contraction certificate exists")
    lq, d = sp.Rational(lim), sp.Rational(max(abs(lim), 1.0)) / 2
    for _ in range(30):
        iv = sp.Interval(lq - d, lq + d)
        q = max(abs(maximum(fp, X, iv)), abs(minimum(fp, X, iv)))
        if q < 1:
            break
        d /= 2
    else:
        raise Undecided("no interval around L on which |f'| < 1")
    xs = gen.generate(row["gen"], max(20000, 10 * row["n"]))
    k = next((i for i, v in enumerate(xs) if abs(v - lim) <= float(d) / 2), None)
    if k is None:
        raise Refused(f"the iterates never enter I = L +- {float(d):.3g}")
    return (f"f(L) = L {'exactly' if exact else 'to 1e-12'}; max |f'| = {float(q):.4f} < 1 on"
            f" L +- {float(d):.4g}; x_{k} is inside")


def in_program(row):
    """affine / pieces: the NaN tail (IEEE), or the exact closed form of the
    last piece on the values the runtime is FED (the float it holds where the
    piece starts, and the piece's a and b, each as its exact binary value),
    which decides the limit and eventual boundedness: finitely many early
    terms, inf included, never matter (#1758 comment 6173870348). |a| > 1
    with a limit means the orbit sits on the repelling fixed point: the
    floats must stay there exactly."""
    g = row["gen"]
    xs = gen.generate(g, row["n"])
    nan_at = next((i for i, v in enumerate(xs) if v != v), None)
    ps = gen.pieces(g)
    s = sum((1 if "x0" in p else 0) + p["steps"] for p in ps[:-1])
    last = ps[-1]
    if nan_at is not None:
        if any(st[0] == "set" for st in gen.program(g, s)[nan_at:]):
            # A later explicit x0 starts a defined tail.  Continue into the
            # ordinary last-piece proof below: finite prefixes do not affect
            # limit notions (#1758), even when the prefix contains NaN.
            pass
        else:
            st = gen.program(g, nan_at)[nan_at]
            if st[0] == "set":
                raise Refused(f"x_{nan_at} is a NaN literal, not a value the program computes")
            return "ieee", {"limit": None, "tends_to": None, "bounded": False}, (
                f"x_{nan_at} = {xs[nan_at - 1]!r} * {st[1]!r} + {st[2]!r} is NaN (IEEE 754 invalid"
                " operation); NaN is absorbing under x * a + b, so every later value is NaN: no"
                " limit, not +-inf, not bounded")
    if "x0" not in last:                              # it starts from the value the earlier pieces leave
        s -= 1
    x_s = gen.generate(g, s)[s]                       # the value the runtime holds there
    if not math.isfinite(x_s):
        raise Undecided(f"x_{s} = {x_s!r} where the last piece starts: no exact closed form from a"
                        " non-finite value")
    a, b, xe = exact(last["a"]), exact(last["b"]), exact(x_s)
    j = N - s
    ex = xe + b * j if a == 1 else a ** j * (xe - b / (1 - a)) + b / (1 - a)
    v, how = limit_of(ex)                 # bounded = EVENTUALLY bounded: the tail decides (#1758)
    nxt = x_s * last["a"] + last["b"]
    if abs(a) > 1 and v["limit"] is not None and nxt != x_s:
        raise Refused(f"|a| = {float(abs(a)):.4g} > 1: x_{s} = {x_s!r} is the repelling fixed point of"
                      f" x <- {last['a']!r} x + {last['b']!r} in exact arithmetic, but the floats the"
                      f" runtime is fed leave it (x_{s + 1} = {nxt!r}) and rounding error grows by |a| per step")
    return "symbolic", v, (f"exact closed form of x <- {last['a']!r} x + {last['b']!r} on the fed"
                           f" values from x_{s} = {x_s!r}: {how}")


def decide(row):
    """(kind, verdict, detail), or raise Undecided / Refused."""
    g, p = row["gen"], row["props"]
    k = g["kind"]
    if k in gen.RANDOM_KINDS:
        raise Undecided("a realization of a random process")
    if k == "cycle":
        vs = g["values"]
        v = {"limit": vs[0] if len(set(vs)) == 1 else None, "tends_to": None, "bounded": True}
        return "exact", v, "a cycle converges iff it is constant"
    if k == "closed":
        ex = parse(g["expr"], {"n": N})
        agree(ex, row)
        return ("symbolic", *limit_of(ex))
    if k in gen.IN_PROGRAM:
        return in_program(row)
    f = parse(g["expr"], {"x": X, "n": N})
    gn = sp.simplify(f - X)
    if X not in gn.free_symbols:                      # x <- x + g(n)
        s = sp.summation(gn.subs(N, I), (I, 1, sp.oo))
        if isinstance(s, sp.Sum):
            raise Undecided(f"sympy cannot sum {gn}")
        if s in (sp.oo, -sp.oo):
            v = {"limit": None, "tends_to": "+inf" if s == sp.oo else "-inf", "bounded": False}
        elif s.is_number and s.is_finite:
            v = {"limit": sp.Rational(repr(g["x0"])) + s, "tends_to": None, "bounded": True}
        else:
            raise Undecided(f"series sum {s}")
        return "symbolic", v, f"x <- x + g(n): x_0 + sum g = {v['limit'] if v['limit'] is not None else v['tends_to']}"
    if N in f.free_symbols:
        raise Undecided("a non-autonomous recurrence that is not x <- x + g(n)")
    if p["limit"] is None:
        raise Undecided("an autonomous recurrence without a stated limit")
    v = {"limit": p["limit"], "tends_to": None, "bounded": True}
    return "fixed-point", v, fixed_point(f, row, p["limit"])


def matches(v, p):
    if (v["limit"] is None) != (p["limit"] is None):
        return False
    return (v["limit"] is None or close(v["limit"], p["limit"])) \
        and v["tends_to"] == p["tends_to"] and v["bounded"] == p["bounded"]


def refute(row, v, kind):
    """Numerics may REFUTE, never prove: raise Refused when the values the
    runtime is fed are inconsistent with the verdict (float-degenerate)."""
    if kind == "ieee":
        return
    n = row["n"]
    xs = gen.generate(row["gen"], n)
    q = max(1, (n + 1) // 4)
    if v["tends_to"]:
        s = 1 if v["tends_to"] == "+inf" else -1
        head, tail = max(s * x for x in xs[:q]), max(s * x for x in xs[-q:])
        if not (tail > head or s * xs[-1] == math.inf):
            raise Refused(f"float-degenerate: the values fed to the runtime do not run to"
                          f" {v['tends_to']}: the last {q} reach {s * tail!r}, the first {q} {s * head!r}")
    elif v["limit"] is not None:           # the error must keep shrinking toward 0
        H = max(10 ** 6, 10 * n)
        far, lim = gen.generate(row["gen"], H), float(v["limit"])
        # A finite NaN prefix is irrelevant to a limit; only an undefined tail
        # refutes it.  `in_program` proved that the last piece restarts finite.
        last_nan = max((i for i, x in enumerate(far) if x != x), default=-1)
        if last_nan >= H // 10:
            raise Refused("float-degenerate: a value the generator computes late is NaN, but the verdict is a limit")
        if not all(math.isfinite(x) for x in far[H // 10:]):
            raise Refused(f"a value the runtime would be fed past x_{H // 10} is infinite: no finite limit {lim!r}")
        dec, end = (max(abs(x - lim) for x in far[k:]) for k in (H // 10, H - H // 10))
        if end > RHO * dec and end > derive.eps(lim):
            raise Refused(f"the error |x - L| does not shrink toward 0: {end:.3g} over the last tenth of"
                          f" {H} terms, {dec:.3g} over the last decade (more than {RHO} of it): no limit"
                          f" {lim!r}, or one the floats cannot show")
    elif len(set(xs[-q:])) < 2:
        raise Refused(f"float-degenerate: no limit, but the last {q} values fed to the runtime"
                      f" are all {xs[-1]!r}")
    if v["bounded"]:
        H = max(20000, 10 * n)
        far = gen.generate(row["gen"], H)
        if not all(math.isfinite(x) for x in xs[len(xs) // 2:] + far[H // 10:]):
            raise Refused(f"eventually bounded, but a late value fed to the runtime (in the row, or past"
                          f" x_{H // 10}) is infinite")


def manual(row, sources, why):
    m = row.get("manual")
    if not m or not m.get("argument") or not m.get("cite") or any(s not in sources for s in m["cite"]) \
            or set(m.get("claims", {})) != {"limit", "tends_to", "bounded"}:
        raise Undecided(f"{why}; add a manual block with an argument, a citation and its claims")
    return "manual", dict(m["claims"]), (f"{m['argument']} [{', '.join(m['cite'])}]"
                                         f" (undecided automatically: {why})")


def _alarm(signum, frame):
    raise SympyTimeout(f"took longer than {ALARM_S} s")


def certify(corpus):
    certs, refused, code = {}, [], derive.code_hash()
    counts = {k: 0 for k in ("symbolic", "exact", "fixed-point", "ieee", "manual")}
    signal.signal(signal.SIGALRM, _alarm)
    for row in corpus["rows"]:
        rid, p = row["id"], row["props"]
        signal.alarm(ALARM_S)
        try:
            const = constant(row)
            try:
                kind, v, detail = decide(row)
                if row.get("manual"):
                    raise Refused(f"manual block unused ({kind} decides it); remove it")
            except Undecided as e:
                kind, v, detail = manual(row, corpus["sources"], str(e))
            if not matches(v, p):
                raise Refused(f"stated limit={p['limit']} tends_to={p['tends_to']}"
                              f" bounded={p['bounded']}, but {kind} gives {v}")
            refute(row, v, kind)
        except (Undecided, Refused) as e:
            refused.append(f"{rid}: {e}")
            continue
        except SympyTimeout as e:
            raise RuntimeError(f"{rid}: the certifier {e}; a timeout is an internal error, not a"
                               " refusal, and never falls through to `manual` (#1766)")
        finally:
            signal.alarm(0)
        counts[kind] += 1
        certs[rid] = {"hash": derive.row_hash(row, code), "kind": kind, "constant": const, "detail": detail}
        print(f"  {rid:22} {kind:11} constant={const!s:5} {detail}")
    return certs, refused, counts


def main(argv):
    if argv[1:] and not (argv[1] == "--corpus" and len(argv) == 3):
        raise gen.HarnessError(f"usage: certify.py [--corpus PATH] (not {' '.join(argv[1:])!r}): the"
                               " certificate is written beside the corpus, so a corpus comes only with --corpus")
    path = argv[2] if argv[1:] else os.path.join(derive.HERE, "corpus.json")
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
    except gen.HarnessError as e:
        print(f"OBSERVER_ORACLE_ERROR: {e}", file=sys.stderr)
        sys.exit(2)
    except Exception as e:          # an instrument crash is never a refusal, never `manual`
        print(f"OBSERVER_ORACLE_ERROR: internal {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(2)
