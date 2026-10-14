"""Independent reference model for the observer predicates (#1746, #1667).

Written from the MATH definitions in corpus.json ("definitions"), not from
the C observer. Every predicate is a pure function of a window `w`: the last
W+1 observed values of one signal, oldest first. Nothing else is read.

Recommended model of the #1746 prior-art comment, section 4, with
`oscillating` taken from Hardy Sec. 62 as the corpus defines it:
  converged    windowed Cauchy test: diameter of the window <= tau
  diverging    Hardy Sec. 60 windowed: same-sign steps above tau that do
               not contract (rho >= 1), or a value that IS infinite
  improving    CONVENTION (#1754): the recent half sets a new low below
               the older half's best by more than min_delta (Keras
               mode='min'); the ratio test survives as _contracting
  oscillating  Hardy Sec. 62 windowed: the window shows neither a limit
               (converged / _contracting) nor a run to +-inf (diverging)
  equilibrium  no CUSUM alarm (NIST e-Handbook 6.3.2.3, k = 0.5 sigma,
               h = 4 sigma) of the recent half against the older half, no
               periodic fluctuation (NIST 6.4.4.2), not diverging
  stable       (EIGS-DEFINED) the converged test at the coarse tolerance

Independence, stated honestly: this is an independent implementation of
the corpus DEFINITIONS, but at the observer's own design parameters (W = 10,
RTOL = dh_zero, RTOL_COARSE = dh_small, SCALE) and with entropy_of_num
copied from the C. Its agreement with the runtime on window-limited rows is
correlated, not independent evidence.

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


def _contracting(w):
    """Ratio test on the steps (Nocedal-Wright App. A.2): every
    |d_{i+1}| / |d_i| < 1 and not yet settled: evidence of a limit."""
    if not _full(w) or not _finite(w) or converged(w):
        return False
    d = _steps(w)
    if any(s == 0.0 for s in d):
        return False
    return all(abs(b) / abs(a) < 1.0 for a, b in zip(d, d[1:]))


def improving(w):
    """CONVENTION (owner ruling, #1754): Keras mode='min', min_delta = rtol*max(|best|, scale). The
    corpus compares the recent best with the best of the whole history; a
    window approximates that history by its older half, so the recent half
    must set a new low below the older half's best by more than min_delta."""
    if len(w) < 2 or not _finite(w):
        return False
    half = (len(w) + 1) // 2
    best = min(w[:half])
    return min(w[half:]) < best - RTOL * max(abs(best), SCALE)


def _periodic(w):
    """Some p in 2..W//2 repeats across the window and one period spans
    more than tau: the periodic fluctuation NIST 6.4.4.2 excludes."""
    t = tau(w[-1])
    for p in range(2, W // 2 + 1):
        cycle = w[-p:]
        if max(cycle) - min(cycle) > t and \
                all(abs(w[i] - w[i - p]) <= t for i in range(p, len(w))):
            return True
    return False


def oscillating(w):
    if not _full(w) or not _finite(w):
        return False
    return not (converged(w) or _contracting(w) or diverging(w))


def equilibrium(w):
    if not _full(w) or not _finite(w):
        return False
    if diverging(w) or _periodic(w):
        return False
    s = max(abs(v) for v in w) or 1.0      # scale-free: no overflow at 1e305
    u = [v / s for v in w]
    half = len(u) // 2
    old, new = u[:half], u[half:]
    mu = sum(old) / len(old)
    sd = math.sqrt(sum((v - mu) * (v - mu) for v in old) / (len(old) - 1))
    sigma = max(sd, tau(w[-1]) / s)
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
