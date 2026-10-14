"""Independent reference model for the observer predicates (#1746, #1667).

Written from the MATH definitions in corpus.json ("definitions"), not from
the C observer. Every predicate is a pure function of a window `w`: the last
W+1 observed values of one signal, oldest first. Nothing else is read.

Recommended model of the #1746 prior-art comment, section 4:
  converged    windowed Cauchy test: diameter of the window <= tau
  diverging    term/ratio test: same-sign steps above tau that do not
               contract (rho >= 1), or a value that IS infinite
  improving    ratio test on the steps: every |d_{i+1}| / |d_i| < 1
  oscillating  periodicity at tolerance: some p in 2..W//2 with
               |w_i - w_{i-p}| <= tau across the window, and one period
               spanning more than tau
  equilibrium  no CUSUM alarm (NIST e-Handbook 6.3.2.3, k = 0.5 sigma,
               h = 4 sigma) of the recent half against the older half,
               and neither diverging nor oscillating
  stable       (EIGS-DEFINED) the converged test at the coarse tolerance

Deviation from the prior-art sketch, on purpose: `oscillating` tests
periodicity (the corpus' MATH definition) instead of Nelson rule 4. Nelson
alternation fires on damped alternating approaches, which converge and so
are not oscillating under that definition.

#1667: `entropy_signal` maps values to the runtime's per-number entropy, so
the same classifier can run on either signal.
"""
import math

RTOL = 1e-3         # docs/SPEC.md dh_zero, the settle tolerance
RTOL_COARSE = 1e-2  # dh_small
SCALE = 1e-3        # obs scale: below it the tolerance turns absolute
W = 10              # window: W steps, W + 1 values


def tau(x, rtol=RTOL):
    return rtol * max(abs(x), SCALE)


def _finite(w):
    return all(math.isfinite(v) for v in w)


def _steps(w):
    return [b - a for a, b in zip(w, w[1:])]


def _full(w):
    return len(w) >= W + 1


def converged(w):
    if not _full(w) or not _finite(w):
        return False
    return max(w) - min(w) <= tau(w[-1])


def diverging(w):
    if w and math.isinf(w[-1]):
        return True                     # the value reached the edge
    if not _full(w) or not _finite(w):
        return False
    d = _steps(w)
    t = tau(w[-1])
    if not (all(s > t for s in d) or all(s < -t for s in d)):
        return False
    ratios = [abs(b) / abs(a) for a, b in zip(d, d[1:])]
    rho = math.exp(sum(math.log(r) for r in ratios) / len(ratios))
    return rho >= 1.0 - 1e-9


def improving(w):
    if not _full(w) or not _finite(w) or converged(w):
        return False
    d = _steps(w)
    if any(s == 0.0 for s in d):
        return False
    return all(abs(b) / abs(a) < 1.0 for a, b in zip(d, d[1:]))


def oscillating(w):
    if not _full(w) or not _finite(w):
        return False
    t = tau(w[-1])
    if max(w) - min(w) <= t:
        return False
    for p in range(2, W // 2 + 1):
        cycle = w[-p:]                  # one period must move above tau
        if max(cycle) - min(cycle) > t and \
                all(abs(w[i] - w[i - p]) <= t for i in range(p, len(w))):
            return True
    return False


def equilibrium(w):
    if not _full(w) or not _finite(w):
        return False
    if diverging(w) or oscillating(w):
        return False
    half = len(w) // 2
    old, new = w[:half], w[half:]
    mu = sum(old) / len(old)
    sd = math.sqrt(sum((v - mu) ** 2 for v in old) / (len(old) - 1))
    sigma = max(sd, tau(w[-1]))
    k, h = 0.5 * sigma, 4.0 * sigma
    hi = lo = 0.0
    for v in new:
        hi = max(0.0, hi + v - mu - k)
        lo = max(0.0, lo + mu - v - k)
        if hi > h or lo > h:
            return False
    return True


def stable(w):
    if not _full(w) or not _finite(w):
        return False
    return max(w) - min(w) <= tau(w[-1], RTOL_COARSE)


PREDICATES = {
    "converged": converged, "stable": stable, "improving": improving,
    "oscillating": oscillating, "diverging": diverging,
    "equilibrium": equilibrium,
}


def classify(values, at):
    """Every predicate on the window ending at index `at` (inclusive)."""
    w = values[max(0, at - W):at + 1]
    return {name: fn(w) for name, fn in PREDICATES.items()}


def entropy_of_num(x):
    """The runtime's per-number entropy, reproduced from
    src/eigenscript.c:356-368 (entropy_of_num): binary entropy h(p) of
    p = 1 / (1 + |x|), 0 at x == 0 and where p rounds to 0 or 1. The
    runtime's dH is the difference of consecutive values of this
    (src/eigenscript.c:731, observer_slot_update_e), so a window of H
    values carries exactly the dH steps the entropy channel classifies."""
    x = abs(x)
    if x == 0.0:
        return 0.0
    p = 1.0 / (1.0 + x)
    if p <= 0.0 or p >= 1.0:
        return 0.0
    return -(p * math.log2(p) + (1.0 - p) * math.log2(1.0 - p))


def entropy_signal(values):
    return [entropy_of_num(v) if not math.isnan(v) else v for v in values]
