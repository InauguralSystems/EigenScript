#!/usr/bin/env python3
"""The standard-test, trivial and persistence arms of #1758's Round 3
pre-registration (comments 6430031838 + 6430139845; RULINGS R30-1..R30-4).

usage: standard.py --check   (the one-time textbook checks; a tools/selftests.txt row)
       standard.py --fit     (C1 and PERSIST refitted on the calibration labels)

Every arm is a pure function f(xs, n) of the values x_0..x_n a row's
generator gives (score.py's held values): the window arms read only
w = xs[n-W .. n] (oldest first, the contract of reference.py); D2 reads the
history, as Keras' running best does. Plain Python, no numpy or scipy (the
CI container has neither): every statistical test is implemented from its
definition, and its source is the line above it. The primary arm (STD) of
each predicate is the registered one; STD' (and STD'' for equilibrium) are
reported and decide nothing. D2 is the ruled Deviation (R30-4 item 2).
"""
import math
import os
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))     # python3 -I drops the script's directory
import reference as R
from reference import W, SCALE, tau

Z975 = statistics.NormalDist().inv_cdf(0.975)     # two-sided alpha = 0.05
DBL_EPSILON = sys.float_info.epsilon
SETTLED = ("converged", "stable", "equilibrium")   # FPR = false-settled; PERSIST's domain (P11)


def win(xs, n):
    return xs[max(0, n - W):n + 1]


def _ok(w):
    return R._full(w) and R._finite(w)


# --- statistical tests, from their definitions ------------------------------

# Mann (1945), Kendall (1975); as in Gilbert, Statistical Methods for
# Environmental Pollution Monitoring (1987) Sec. 16.4 and pyMannKendall
# original_test (S, the tie-corrected Var S, Z = (S - sgn S)/sqrt(Var S),
# two-sided normal p), verified against pymannkendall.py (master, 2026-11-03).
def mann_kendall(x):
    n = len(x)
    s = sum((x[j] > x[i]) - (x[j] < x[i]) for i in range(n) for j in range(i + 1, n))
    ties = {}
    for v in x:
        ties[v] = ties.get(v, 0) + 1
    var = (n * (n - 1) * (2 * n + 5) - sum(t * (t - 1) * (2 * t + 5) for t in ties.values())) / 18
    z = 0.0 if s == 0 or var <= 0 else (s - (1 if s > 0 else -1)) / math.sqrt(var)
    return s, var, z


def mk_trend(x):
    return abs(mann_kendall(x)[2]) > Z975


# Regularized incomplete beta I_x(a, b): Numerical Recipes 3rd ed. Sec. 6.4,
# eq. 6.4.5 continued fraction, modified Lentz.
def betainc(a, b, x):
    if x <= 0.0:
        return 0.0
    if x >= 1.0:
        return 1.0
    if x > (a + 1) / (a + b + 2):
        return 1.0 - betainc(b, a, 1.0 - x)
    lbt = math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b) + a * math.log(x) + b * math.log1p(-x)
    tiny, c, d = 1e-300, 1.0, 1.0 - (a + b) * x / (a + 1)
    d = 1.0 / (d if abs(d) > tiny else tiny)
    h = d
    for m in range(1, 300):
        for num in (m * (b - m) * x / ((a + 2 * m - 1) * (a + 2 * m)),
                    -(a + m) * (a + b + m) * x / ((a + 2 * m) * (a + 2 * m + 1))):
            d = 1.0 + num * d
            d = 1.0 / (d if abs(d) > tiny else tiny)
            c = 1.0 + num / c
            c = c if abs(c) > tiny else tiny
            h *= d * c
        if abs(d * c - 1.0) < 1e-15:
            break
    return math.exp(lbt) * h / a


def f_cdf(f, d1, d2):
    return betainc(d1 / 2, d2 / 2, d1 * f / (d1 * f + d2)) if f > 0 else 0.0


def f_quantile(q, d1, d2):
    lo, hi = 0.0, 1.0
    while f_cdf(hi, d1, d2) < q:
        hi *= 2
    for _ in range(200):
        mid = (lo + hi) / 2
        lo, hi = (mid, hi) if f_cdf(mid, d1, d2) < q else (lo, mid)
    return (lo + hi) / 2


# NIST/SEMATECH e-Handbook 1.3.5.9, F-test for equality of two variances
# (F = s1^2/s2^2, two-tailed: reject outside [F(1-a/2), F(a/2)]), verified
# against itl.nist.gov/div898/handbook/eda/section3/eda359.htm (2026-11-03).
def f_variance_change(old, new):
    v1, v2 = statistics.variance(old), statistics.variance(new)
    if v1 == 0.0 or v2 == 0.0:
        return v1 != v2                 # one half constant, the other not
    p = f_cdf(v1 / v2, len(old) - 1, len(new) - 1)
    return min(p, 1.0 - p) < 0.025


# Turning-point test: Brockwell & Davis, Introduction to Time Series and
# Forecasting, 2nd ed. (2002), Sec. 1.6, test (c): under iid, T is about
# N(2(n-2)/3, (16n-29)/90) (not fetched: the moments are checked by
# exhaustive enumeration in --check instead).
def turning_points(x):
    return sum(1 for a, b, c in zip(x, x[1:], x[2:]) if (b > a and b > c) or (b < a and b < c))


# KPSS level stationarity: Kwiatkowski, Phillips, Schmidt & Shin (1992),
# J. Econometrics 54, eqs. 10-11, 5% critical value 0.463 (Table 1, eta_mu);
# lags by statsmodels' default nlags="auto" (Hobijn et al. 1998), verified
# against statsmodels v0.14.4 tsa/stattools.py kpss/_kpss_autolag/_sigma_est_kpss.
def kpss_lags(e):
    n = len(e)
    covlags, s1, s0 = int(n ** (2.0 / 9.0)), 0.0, sum(r * r for r in e) / n
    for i in range(1, covlags + 1):
        prod = sum(a * b for a, b in zip(e[i:], e[:n - i])) / (n / 2.0)
        s0, s1 = s0 + prod, s1 + i * prod
    return min(int(1.1447 * ((s1 / s0) ** 2) ** (1 / 3) * n ** (1 / 3)), n - 1)


def kpss_stat(x):
    n = len(x)
    m = sum(x) / n
    e = [v - m for v in x]
    if all(r == 0.0 for r in e):
        return 0.0
    lags = kpss_lags(e)
    sig = sum(r * r for r in e)
    for i in range(1, lags + 1):
        sig += 2 * sum(a * b for a, b in zip(e[i:], e[:n - i])) * (1.0 - i / (lags + 1.0))
    part, acc = 0.0, 0.0
    for r in e:
        acc += r
        part += acc * acc
    return (part / n ** 2) / (sig / n) if sig > 0 else 0.0


# --- the arms ---------------------------------------------------------------

# converged STD: windowed Cauchy criterion (Rudin, Principles of Mathematical
# Analysis 3rd ed., Def. 3.8 / Thm. 3.11), diameter <= tau = 1e-3*max(|x|, 1e-3):
# reference.converged exactly.
def std_converged(xs, n):
    return R.converged(win(xs, n))


# converged STD': numpy.isclose(x_k, x_{k-1}, rtol=1e-3, atol=1e-6) for every
# step of the window (|a - b| <= atol + rtol*|b|; corpus source ISCLOSE).
def isclose(a, b, rtol, atol):
    return abs(a - b) <= atol + rtol * abs(b)


def stdp_converged(xs, n):
    w = win(xs, n)
    return _ok(w) and all(isclose(b, a, 1e-3, 1e-6) for a, b in zip(w, w[1:]))


# stable STD: the 2% settling band (python-control step_info
# SettlingTimeThreshold = 0.02; corpus PYCONTROL_STEPINFO, SETTLING_WIKI):
# diameter <= 2*0.02*max(|mean|, 1e-3).
def std_stable(xs, n):
    w = win(xs, n)
    if not _ok(w):
        return False
    m = sum(w) / len(w)
    return max(w) / 2 - min(w) / 2 <= 0.02 * max(abs(m), SCALE)


# stable STD' = Deviation D1: reference.stable exactly (1% ball about the midrange).
def stdp_stable(xs, n):
    return R.stable(win(xs, n))


# improving STD: Keras EarlyStopping mode='min' over halves with the relative
# min_delta, plus reference.py's bounded approximation: reference.improving.
def std_improving(xs, n):
    return R.improving(win(xs, n))


def _bounded(w):
    return not (R.diverging(w) or (R._full(w) and R._expanding(w)))


# improving STD': PyTorch ReduceLROnPlateau defaults (mode='min',
# threshold=1e-4, threshold_mode='rel', patience=10): is_better(a, best) =
# a < best*(1 - 1e-4), verified against torch/optim/lr_scheduler.py v2.5.1.
# Over the window, best starts at its first value (the scheduler's best=inf
# would count w[0] itself); an improvement within the window's 10 steps.
def stdp_improving(xs, n):
    w = win(xs, n)
    if len(w) < 2:
        return False
    best, hit = w[0], False
    for v in w[1:]:
        if v < best * (1.0 - 1e-4):
            best, hit = v, True
    return hit


# improving D2 (RULING R30-4 item 2): Keras EarlyStopping's running best
# (keras/src/callbacks/early_stopping.py v3.6.0: _is_improvement =
# monitor - min_delta < best, min_delta negated for 'min') over the history,
# min_delta = 1e-3*max(|best|, 1e-3); (a) a non-finite best is no best yet;
# (b) false while the window holds a non-finite value; (c) the baseline x_0
# is never an improvement; patience = the window; plus the bounded approximation.
def d2_improving(xs, n):
    best, last = None, None
    for i in range(n + 1):
        v = xs[i]
        if not math.isfinite(v):
            continue
        if best is None:
            best = v
        elif v < best - 1e-3 * max(abs(best), SCALE):
            best, last = v, i
    w = win(xs, n)
    return last is not None and last >= n - W + 1 and R._finite(w) and _bounded(w)


# oscillating STD: Hardy Sec. 62's complement, windowed: reference.oscillating.
def std_oscillating(xs, n):
    return R.oscillating(win(xs, n))


# oscillating STD': the turning-point test at alpha = 0.05 (Brockwell & Davis
# Sec. 1.6): oscillating unless T is significantly LOW (a trend or a limit).
def stdp_oscillating(xs, n):
    w = win(xs, n)
    if not _ok(w):
        return False
    k = len(w)
    return (turning_points(w) - 2 * (k - 2) / 3) / math.sqrt((16 * k - 29) / 90) >= -Z975


def _rho_ge_1(w):
    d = R._steps(w)
    if any(s == 0 for s in d):
        return False
    r = [abs(b) / abs(a) for a, b in zip(d, d[1:])]
    return math.exp(sum(math.log(q) for q in r) / len(r)) >= 1.0 - 1e-9


# diverging STD: Mann-Kendall two-sided alpha = 0.05 on the window's 11 values
# AND step ratio rho >= 1 (rho: the geometric mean of |d_{k+1}|/|d_k|, with
# reference.py's 1e-9 float slack).
def std_diverging(xs, n):
    w = win(xs, n)
    return _ok(w) and mk_trend(w) and _rho_ge_1(w)


# diverging STD': reference.diverging (Hardy Sec. 60 windowed).
def stdp_diverging(xs, n):
    return R.diverging(win(xs, n))


# equilibrium STD: constant within 4*DBL_EPSILON*(1 + |x|), OR all three NIST
# 6.4.4.2 checks (corpus NIST_6442): no Mann-Kendall trend, no F-test variance
# change between the halves (both at alpha = 0.05), no period (reference._periodic).
def std_equilibrium(xs, n):
    w = win(xs, n)
    if not _ok(w):
        return False
    if max(w) - min(w) <= 4 * DBL_EPSILON * (1 + abs(w[-1])):
        return True
    h = len(w) // 2
    fw = [float(v) for v in w]
    return not (mk_trend(w) or f_variance_change(fw[:h], fw[h:]) or R._periodic(w))


# equilibrium STD': KPSS level stationarity, not rejected at 5% (eta <= 0.463).
def stdp_equilibrium(xs, n):
    w = win(xs, n)
    return _ok(w) and kpss_stat([float(v) for v in w]) <= 0.463


# equilibrium STD'': CUSUM (NIST 6.3.2.3), reference.equilibrium.
def stdpp_equilibrium(xs, n):
    return R.equilibrium(win(xs, n))


# PERSIST (P11): settled if max |dx| over the window < theta*max(|x_n|, 1e-3).
def persist(theta):
    def arm(xs, n):
        w = win(xs, n)
        return _ok(w) and max(abs(s) for s in R._steps(w)) < theta * max(abs(w[-1]), SCALE)
    return arm


THETAS = [10 ** (-5 + k / 2) for k in range(9)]     # 10^{-5, -4.5, ..., -1}
# Fitted by `standard.py --fit` on the calibration labels (corpus.json + hcal/):
# frozen here; judge.py refuses to score when a refit disagrees.
C1_MAJORITY = {"converged": False, "stable": False, "improving": False,
               "oscillating": False, "diverging": False, "equilibrium": False}
PERSIST_THETA = {"converged": THETAS[6], "stable": THETAS[6], "equilibrium": THETAS[1]}   # 1e-2, 1e-2, 10^-4.5

ARMS = {
    "STD": {"converged": std_converged, "stable": std_stable, "improving": std_improving,
            "oscillating": std_oscillating, "diverging": std_diverging, "equilibrium": std_equilibrium},
    "STD'": {"converged": stdp_converged, "stable": stdp_stable, "improving": stdp_improving,
             "oscillating": stdp_oscillating, "diverging": stdp_diverging, "equilibrium": stdp_equilibrium},
    "STD''": {"equilibrium": stdpp_equilibrium},
    "D2": {"improving": d2_improving},
    "REF": {p: (lambda f: lambda xs, n: f(win(xs, n)))(f) for p, f in R.PREDICATES.items()},
    "C0": {p: (lambda xs, n: False) for p in R.PREDICATES},
    "C1": {p: (lambda v: lambda xs, n: v)(v) for p, v in C1_MAJORITY.items()},
    "PERSIST": {p: persist(t) for p, t in PERSIST_THETA.items()},
}


def balanced(c):
    """(TPR + TNR) / 2 from [TP, FP, FN, TN], None when a class is absent."""
    tp, fp, fn, tn = c
    return None if tp + fn == 0 or tn + fp == 0 else (tp / (tp + fn) + tn / (tn + fp)) / 2


def fit(items):
    """C1 and PERSIST from [(pred, label, xs, n)]: the majority class (a tie
    is False) and the grid theta of best BA (a tie takes the smaller theta)."""
    c1, th = {}, {}
    for p in R.PREDICATES:
        labs = [lab for q, lab, _x, _n in items if q == p]
        c1[p] = sum(labs) * 2 > len(labs)
    for p in SETTLED:
        best = None
        for t in THETAS:
            c = [0, 0, 0, 0]
            for q, lab, xs, n in items:
                if q == p:
                    c[{(True, True): 0, (False, True): 1, (True, False): 2, (False, False): 3}[(lab, persist(t)(xs, n))]] += 1
            if best is None or balanced(c) > best[0]:
                best = (balanced(c), t)
        th[p] = best[1]
        print(f"PERSIST {p}: theta = {best[1]:.6g}, calibration BA {best[0]:.4f}")
    return c1, th


def check():
    """One-time textbook checks (docs/PRINCIPLES.md section 5); each prints CHECK ok/FAIL."""
    import itertools
    from gen import generate
    res = []
    def ok(name, cond):
        res.append(cond)
        print(f"CHECK {'ok' if cond else 'FAIL'}: {name}")
    # numpy.isclose documentation examples (rtol=1e-5, atol=1e-8)
    ok("isclose numpy doc examples", [isclose(a, b, 1e-5, 1e-8) for a, b in
       ((1e10, 1.00001e10), (1e-7, 1e-8), (1e-8, 1e-9), (1e10, 1.0001e10))] == [True, False, True, False])
    ok("normal z(0.975) = 1.959964", abs(Z975 - 1.959964) < 1e-6)
    # NIST 1.3.5.9 worked example: 239/239 df critical values 0.7756 and 1.2894; F = 1.123037
    ok("F critical values, NIST 1.3.5.9 example", abs(f_quantile(0.025, 239, 239) - 0.7756) < 5e-5
       and abs(f_quantile(0.975, 239, 239) - 1.2894) < 5e-5 and abs((65.54909 / 61.85425) ** 2 - 1.123037) < 1e-5)
    ok("F table F(0.975; 5, 4) = 9.3645, F(0.975; 4, 5) = 7.3879",
       abs(f_quantile(0.975, 5, 4) - 9.3645) < 5e-4 and abs(f_quantile(0.975, 4, 5) - 7.3879) < 5e-4)
    # Mann-Kendall: exact S and Var S by definition; a monotone 11-window rejects, a tie-heavy one does not
    s, var, z = mann_kendall(list(range(11)))
    ok("Mann-Kendall monotone n=11: S=55, Var S=165, Z=54/sqrt(165) rejects", s == 55 and var == 165
       and abs(z - 54 / math.sqrt(165)) < 1e-12 and mk_trend(list(range(11))))
    s, var, z = mann_kendall([1, 1, 2, 2, 1, 1, 2, 2, 1, 1, 2])
    ok("Mann-Kendall ties: Var S = (11*10*27 - 5*4*15 - 6*5*17)/18", var == (2970 - 300 - 510) / 18 and not mk_trend([1, 1, 2, 2, 1, 1, 2, 2, 1, 1, 2]))
    # Mann-Kendall S under H0 equals the exact Kendall distribution's variance (n = 6, all permutations)
    perms = list(itertools.permutations(range(6)))
    ss = [mann_kendall(list(p))[0] for p in perms]
    ok("Mann-Kendall Var S = n(n-1)(2n+5)/18 exactly over all 720 permutations of n=6",
       sum(ss) == 0 and sum(x * x for x in ss) / len(ss) == 6 * 5 * 17 / 18)
    # turning-point moments by exhaustive enumeration (n = 7, all 5040 permutations)
    perms = list(itertools.permutations(range(7)))
    ts = [turning_points(list(p)) for p in perms]
    m = sum(ts) / len(ts)
    ok("turning points E[T] = 2(n-2)/3, Var T = (16n-29)/90 over all permutations of n=7",
       abs(m - 10 / 3) < 1e-12 and abs(sum((t - m) ** 2 for t in ts) / len(ts) - (16 * 7 - 29) / 90) < 1e-12)
    ok("turning points are strict: [1, 2, 2, 1] has none, [1, 2, 1, 2] has two",
       turning_points([1, 2, 2, 1]) == 0 and turning_points([1, 2, 1, 2]) == 2)
    # KPSS lags by hand for the centred ramp -5..5: covlags 1, s0 = 10 + 80/5.5, s1 = 80/5.5,
    # 1.1447 * ((s1/s0)^2)^(1/3) * 11^(1/3) = 1.796 -> 1 lag
    ok("KPSS auto lags (Hobijn) = 1 for the 11-point ramp, by hand", kpss_lags([float(k) for k in range(-5, 6)]) == 1)
    # KPSS: a ramp rejects level stationarity; alternation and a constant do not
    ok("KPSS ramp 0..10 rejects (eta > 0.463); +-1 alternation and a constant do not",
       kpss_stat([float(i) for i in range(11)]) > 0.463 and kpss_stat([(-1.0) ** i for i in range(11)]) <= 0.463
       and kpss_stat([2.0] * 11) == 0.0)
    # PyTorch rel threshold: best 1.0 -> 0.9999 is not better, 0.99989 is
    ok("ReduceLROnPlateau rel 1e-4: 0.9999 not better than 1.0, 0.99989 better",
       not stdp_improving([1.0] * 10 + [0.9999], 10) and stdp_improving([1.0] * 10 + [0.99989], 10))
    # D2 probes, from the design's Deviations table (R30-3/R30-4)
    loss = [math.inf] + [100 * 0.8 ** k for k in range(1, 40)]
    ok("D2: [inf] + 100*0.8^k reads improving first at @11 (a), never at @1..@10",
       [d2_improving(loss, n) for n in range(1, 12)] == [False] * 10 + [True])
    dec = [100 * 0.8 ** k for k in range(40)]
    nan = dec[:10] + [math.nan] + dec[11:]
    ok("D2: a decreasing loss with a NaN at 10 reads false at @10..@20 (b), true at @21",
       not any(d2_improving(nan, n) for n in range(10, 21)) and d2_improving(nan, 21) and d2_improving(dec, 15))
    ok("D2: x_0 is never an improvement (c): a constant reads false", not any(d2_improving([3.0] * 20, n) for n in range(20)))
    ok("stable STD 2% vs STD' 1%: diameter 0.03 about 1 is 2%-stable, not 1%-stable",
       std_stable([1.0, 1.03] * 6, 11) and not stdp_stable([1.0, 1.03] * 6, 11))
    # equilibrium STD: iid noise is stationary, a decay is not, period 2 is not, a constant is
    noise = generate({"kind": "noise", "center": 5.0, "amp": 0.1, "seed": 3}, 10)
    ok("equilibrium STD: noise yes, geometric decay no, period-2 no, constant yes",
       std_equilibrium(noise, 10) and not std_equilibrium([0.9 ** k for k in range(11)], 10)
       and not std_equilibrium([1.0, 2.0] * 6, 10) and std_equilibrium([7.0] * 11, 10))
    ok("diverging STD: linear yes, geometric growth yes, decay no, noise no",
       std_diverging([float(k) for k in range(11)], 10) and std_diverging([1.5 ** k for k in range(11)], 10)
       and not std_diverging([0.9 ** k for k in range(11)], 10) and not std_diverging(noise, 10))
    print(f"standard checks: {len(res)} examined, {sum(res)} ok, {len(res) - sum(res)} failed")
    return 0 if all(res) and res else 1


def calibration_items():
    import json
    import derive
    from gen import generate
    here, items = os.path.dirname(os.path.abspath(__file__)), []
    for sub in ("", "hcal"):
        d = os.path.join(here, sub)
        corpus = derive.load_corpus(os.path.join(d, "corpus.json"))
        labels = json.load(open(os.path.join(d, "labels.json")))
        for row in corpus["rows"]:
            xs = generate(row["gen"], row["n"])
            for at in row["checkpoints"]:
                for p in R.PREDICATES:
                    e = labels[f"{row['id']}@{at}"][p]
                    if e[0] != "REPORTED":
                        items.append((p, e[1], xs, at))
    return items


if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:
        sys.exit(check())
    if sys.argv[1:] == ["--fit"]:
        c1, th = fit(calibration_items())
        print(f"C1_MAJORITY = {c1}\nPERSIST_THETA = {th}")
        sys.exit(0 if (c1, th) == (C1_MAJORITY, PERSIST_THETA) else 1)
    sys.exit(__doc__)
