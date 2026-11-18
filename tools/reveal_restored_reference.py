#!/usr/bin/env python3
"""An independent reference for `converged` and `stable` after the reveal (#2407).

usage: reveal_restored_reference.py [--raw PATH] [--table PATH]

It shares no code with the runtime or with tools/observer_oracle/: the row's
values are generated here from the corpus row, and the two tests are written
from the decision of #2407 and from the incumbent's source (release v0.47.0,
src/eigenscript.c: obs_num_converged, obs_num_stable, obs_num_flags,
observer_slot_raw_nonvanishing, observer_slot_raw_diverging,
observer_slot_raw_oscillating, observer_slot_saturated, and the value
recorder observer_slot_record_value).

The test, over the last W = 10 steps (each step relative to the larger of the
two values it joins and of the scale 0.001):
  converged: a full window, no |relative step| reaches 0.001, and the window
             is neither raw-diverging nor raw-oscillating;
  stable:    a full window, the same two exclusions, no |relative step|
             reaches 0.01, and no two steps in a row of opposite sign that are
             both larger than 0.001.
Two modes:
  incumbent: values read as doubles; the raw tests' noise floor is
             4 eps (1 + |last value|); a last value at or above 1e308 is
             refused (both false). This is v0.47.0.
  branch:    a step between two exact integers is taken exactly; the noise
             floor is 0 for a window of exact-integer steps; a window that
             holds a value that is not finite (the W + 1 values its steps
             join) is refused; 1e308 is a finite number like any other.

Run as a program it is the test: the incumbent mode must give the arm INC's
answer on all 1,862 of INC's readings of the two predicates in the reveal's
raw log, and the branch mode the table's answer on all 1,904. It prints both
counts and every key that differs, and exits 0 only on 1862/1862 and
1904/1904 (1 on a difference, 2 on an unusable input).
"""
import hashlib
import json
import math
import os
import random
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW_SHA256 = "a080bfba8b650418971bbe7926dbca40bc352b0df84e4720c5e042a141196d09"
RAW_AT_TAG = "phase2-r3-reveal:reveal-r3/result/raw.json"
H1_SHA256 = "85be07d96390ad23f583d640be4fe46fa7a1d4affde37e82bf7125535e016cff"
CORPORA = {"calibration": "tools/observer_oracle/corpus.json",
           "hcal": "tools/observer_oracle/hcal/corpus.json",
           "H1": "tests/phase2/reveal_h1/corpus.json"}
TABLE = "tests/phase2/reveal_restored_expected.json"
WANT = {"incumbent": 1862, "branch": 1904}

W = 10                  # OBSERVER_WINDOW_N
SCALE = 0.001           # the state's scale: the magnitude under which the tolerance turns absolute
DH_ZERO = 0.001         # converged's band
DH_SMALL = 0.01         # stable's band
NUM_MAX = 1e308         # v0.47.0's saturation ceiling (EIGS_NUM_MAX)
EPS = 2.0 ** -52        # DBL_EPSILON
INT64 = (-2 ** 63, 2 ** 63)
PREDS = ("converged", "stable")


class Unusable(Exception):
    pass


# --- the row's values ---------------------------------------------------------

# A corpus expression is checked-in repository data (H1's is checked by its
# sha256 first), evaluated with no builtins, as the corpus defines it.
def _eval_env():
    return {"__builtins__": {}, "math": math, "step": lambda n, c: 1.0 if n >= c else 0.0}


def values(row):
    """x_0..x_n as the runtime holds them: an int64-capability row keeps exact
    Python ints, every other row is read as doubles (the scorer's float
    scaffolding). x * a + b overflows to inf and inf * 0 is NaN, as in IEEE."""
    g, n = row["gen"], row["n"]
    k = g["kind"]
    if k in ("affine", "pieces"):
        pieces = [{"x0": g["x0"], "a": g["a"], "b": g["b"]}] if k == "affine" else g["pieces"]
        xs = []
        for p in pieces:
            if "x0" in p:
                xs.append(p["x0"])
            for _ in range(p.get("steps", n + 1)):
                if len(xs) > n:
                    break
                xs.append(xs[-1] * p["a"] + p["b"])
            if len(xs) > n:
                break
        xs = xs[:n + 1]
    elif k == "closed":
        f = eval(f"lambda n: ({g['expr']})", _eval_env())
        xs = [f(i) for i in range(n + 1)]
    elif k == "recur":
        f = eval(f"lambda x, n: ({g['expr']})", _eval_env())
        xs = [g["x0"]]
        for i in range(1, n + 1):
            xs.append(float(f(xs[-1], i)))
    elif k == "cycle":
        xs = [g["values"][i % len(g["values"])] for i in range(n + 1)]
    elif k == "noise":
        rng = random.Random(g["seed"])
        xs = [g["center"] + g["amp"] * rng.uniform(-1.0, 1.0) for _ in range(n + 1)]
    elif k == "walk":
        rng = random.Random(g["seed"])
        xs = [g["x0"]]
        for _ in range(n):
            xs.append(xs[-1] + (g["step"] if rng.random() < 0.5 else -g["step"]))
    elif k == "ar1":
        rng, x, xs = random.Random(g["seed"]), g["mu"], []
        for i in range(g["burn"] + n + 1):
            if i >= g["burn"]:
                xs.append(x)
            x = g["mu"] + g["phi"] * (x - g["mu"]) + g["sigma"] * rng.uniform(-1.0, 1.0)
    elif k == "uwalk":
        rng = random.Random(g["seed"])
        xs = [g["x0"]]
        for _ in range(n):
            xs.append(xs[-1] + g["step"] * rng.uniform(-1.0, 1.0))
    else:
        raise Unusable(f"{row['id']}: unknown generator kind {k!r}")
    if len(xs) != n + 1:
        raise Unusable(f"{row['id']}: generated {len(xs)} values, not {n + 1}")
    if row.get("capability") == "int64":
        if not all(isinstance(v, int) and INT64[0] <= v < INT64[1] for v in xs):
            raise Unusable(f"{row['id']}: an int64 row must generate int64 values")
        return xs
    return [float(v) for v in xs]


# --- the two tests ------------------------------------------------------------

def _steps(xs, c, mode):
    """The window at checkpoint c, newest first: (relative, raw, exact) per step."""
    out = []
    for i in range(c, max(c - W, 0), -1):
        v, u = xs[i], xs[i - 1]
        exact = mode == "branch" and isinstance(v, int) and isinstance(u, int) \
            and INT64[0] <= v - u < INT64[1]
        raw = float(v - u) if exact else float(v) - float(u)
        a = max(abs(float(v)), abs(float(u)), SCALE)
        out.append((raw / a, raw, exact))
    return out


def _floor(win, last, mode):
    if mode == "branch" and win and all(e for _, _, e in win):
        return 0.0
    return 4.0 * EPS * (1.0 + abs(last))


def _nonvanishing(win, fl):
    cnt = len(win)
    if cnt < 4:
        return False
    half = cnt // 2
    recent = older = 0.0
    for i in range(half):
        recent += abs(win[i][1])
    for i in range(half, cnt):
        older += abs(win[i][1])
    recent /= half
    older /= cnt - half
    if older <= fl or recent <= fl:
        return False
    return recent >= older * (1.0 - 1e-9)


def _raw_diverging(win, fl):
    if not _nonvanishing(win, fl):
        return False
    return all(win[i][1] * win[0][1] > 0.0 for i in range(1, len(win)))


def _raw_oscillating(win, fl):
    if not _nonvanishing(win, fl):
        return False
    flips = sum(1 for i in range(len(win) - 1)
                if win[i][1] * win[i + 1][1] < 0.0 and abs(win[i][1]) > fl and abs(win[i + 1][1]) > fl)
    return flips >= (W + 2) // 3


def classify(xs, c, mode):
    """{converged, stable} at checkpoint c (x_0..x_c assigned)."""
    if mode not in WANT:
        raise ValueError(mode)
    last = float(xs[c])
    if mode == "incumbent" and abs(last) >= NUM_MAX:
        return {"converged": False, "stable": False}
    if mode == "branch" and not all(math.isfinite(float(v)) for v in xs[max(c - W, 0):c + 1]):
        return {"converged": False, "stable": False}
    win = _steps(xs, c, mode)
    if len(win) < W:
        return {"converged": False, "stable": False}
    fl = _floor(win, last, mode)
    if _raw_diverging(win, fl) or _raw_oscillating(win, fl):
        return {"converged": False, "stable": False}
    rel = [r for r, _, _ in win]
    converged = all(abs(r) < DH_ZERO for r in rel)
    stable = all(abs(r) < DH_SMALL for r in rel) and not any(
        rel[i] * rel[i + 1] < 0.0 and abs(rel[i]) > DH_ZERO and abs(rel[i + 1]) > DH_ZERO
        for i in range(W - 1))
    return {"converged": converged, "stable": stable}


# --- the test -----------------------------------------------------------------

def _read(path):
    with open(path, "rb") as f:
        return f.read()


def load_raw(path):
    if path is None:
        p = subprocess.run(["git", "-C", ROOT, "show", RAW_AT_TAG], capture_output=True)
        if p.returncode != 0:
            raise Unusable(f"git show {RAW_AT_TAG} failed (is the tag fetched?): {p.stderr.decode().strip()}")
        data = p.stdout
    else:
        data = _read(path)
    if hashlib.sha256(data).hexdigest() != RAW_SHA256:
        raise Unusable(f"raw.json is not the reveal's (sha256 {RAW_SHA256})")
    return json.loads(data)


def load_corpora():
    out = {}
    for pop, rel in CORPORA.items():
        data = _read(os.path.join(ROOT, rel))
        if pop == "H1" and hashlib.sha256(data).hexdigest() != H1_SHA256:
            raise Unusable(f"{rel} is not H1 as the reveal's tag has it (sha256 {H1_SHA256})")
        out[pop] = {r["id"]: r for r in json.loads(data)["rows"]}
    return out


def expectations(raw, table):
    """mode -> {(population, row@checkpoint, predicate): answer}."""
    inc = {}
    for pop, body in raw["populations"].items():
        for arm, rid, at, p, v in body["readings"]:
            if arm == "INC" and p in PREDS:
                key = (pop, f"{rid}@{at}", p)
                if key in inc:
                    raise Unusable(f"INC {key}: a doubled reading")
                inc[key] = v
    branch = {(pop, k, p): cell[p] for pop, cells in table["populations"].items()
              for k, cell in cells.items() for p in PREDS}
    return {"incumbent": inc, "branch": branch}


def compare(corpora, want, mode):
    """(examined, [differing keys]) for one mode's expectations."""
    cache, diff = {}, []
    for (pop, key, p), answer in sorted(want.items()):
        rid, at = key.rsplit("@", 1)
        row = corpora[pop][rid]
        if (pop, rid) not in cache:
            cache[(pop, rid)] = values(row)
        if classify(cache[(pop, rid)], int(at), mode=mode)[p] != answer:
            diff.append((pop, key, p, answer))
    return len(want), diff


def main(argv):
    args, opts = argv[1:], {}
    while args:
        flag = args.pop(0)
        if flag not in ("--raw", "--table") or not args:
            print(__doc__, file=sys.stderr)
            return 2
        opts[flag] = args.pop(0)
    try:
        raw = load_raw(opts.get("--raw"))
        table = json.loads(_read(opts.get("--table", os.path.join(ROOT, TABLE))))
        corpora = load_corpora()
        exp = expectations(raw, table)
    except (Unusable, OSError, ValueError, KeyError) as e:
        print(f"REVEAL_REFERENCE_ERROR: {e}", file=sys.stderr)
        return 2
    fail = 0
    for mode, want in exp.items():
        n, diff = compare(corpora, want, mode)
        agree = n - len(diff)
        print(f"reference {mode} mode: {agree}/{n} answers agree"
              f" ({'INC in raw.json' if mode == 'incumbent' else 'the table'}), {len(diff)} differ")
        for pop, key, p, answer in diff:
            print(f"  DIFFERS {mode} {pop} {key} {p}: expected {str(answer).lower()}")
        if n != WANT[mode] or diff:
            fail = 1
            if n != WANT[mode]:
                print(f"  COUNT {mode}: {n} answers examined, the bar declares {WANT[mode]}")
    print(f"reference exit {fail}")
    return fail


if __name__ == "__main__":
    sys.exit(main(sys.argv))
