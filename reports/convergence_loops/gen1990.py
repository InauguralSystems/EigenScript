#!/usr/bin/env python3
"""Population generator for EigenScript#1990 (registration amendment 1).

Deterministic: the same SEED gives a byte-identical manifest. Every choice the
registration left open is fixed below and named in the amendment comment.

  python3 gen1990.py manifest.json      # writes the manifest, prints its sha256
  python3 gen1990.py --noise DIR        # writes M8 noise files, prints the sha256 of all noise
"""
import hashlib, json, math, random, sys

SEED = 1990_2026_10_28          # the logged population seed
DRAWS = 25                       # per deterministic family
M8_SEEDS = 10                    # noise seeds per M8 draw
NOISE_LEN = 20_000               # u values per (M8 draw, seed): the harness bound for INC-bare (2x the 10,000 caps)
LYAP_BURN, LYAP_N, LYAP_MIN = 1_000, 100_000, 0.05

def lu(r, lo, hi):               # 10**U(lo, hi)
    return 10 ** r.uniform(lo, hi)

def sign(r):
    return 1.0 if r.random() < 0.5 else -1.0

def lin_params(r, a_lo, a_hi):  # M1/M4/M8 shape: L, a, x0
    L = sign(r) * lu(r, -3, 4)
    a = r.uniform(a_lo, a_hi)
    d = sign(r) * lu(r, -2, 1)
    x0 = L + d * max(abs(L), 1.0)
    return {"L": L, "a": a, "x0": x0}

def lyapunov(rr):
    x = 0.5
    for _ in range(LYAP_BURN):
        x = rr * x * (1 - x)
    s = 0.0
    for _ in range(LYAP_N):
        x = rr * x * (1 - x)
        s += math.log(abs(rr * (1 - 2 * x)) + 1e-300)
    return s / LYAP_N

def build():
    r = random.Random(SEED)
    runs = []
    for i in range(DRAWS):
        runs.append({"family": "M1", "draw": i, "map": "linear", **lin_params(r, 0.1, 0.999)})
    for i in range(DRAWS):
        c = lu(r, -2, 6)
        runs.append({"family": "M2", "draw": i, "map": "newton_sqrt", "c": c, "x0": c, "L": math.sqrt(c)})
    for i in range(DRAWS):              # round-robin over the two registered variants
        if i % 2 == 0:
            runs.append({"family": "M3", "draw": i, "map": "sin", "x0": r.uniform(0.5, 1.5), "L": 0.0})
        else:
            runs.append({"family": "M3", "draw": i, "map": "x_over_1px", "x0": r.uniform(0.5, 5.0), "L": 0.0})
    for i in range(DRAWS):
        runs.append({"family": "M4", "draw": i, "map": "linear", **lin_params(r, -0.999, -0.1)})
    for i in range(DRAWS):              # round-robin over the four registered variants
        v = i % 4
        x0 = sign(r) * lu(r, -2, 1)
        if v == 0:
            runs.append({"family": "M5", "draw": i, "map": "add_c", "c": sign(r) * lu(r, -3, 1), "x0": x0})
        elif v == 1:
            runs.append({"family": "M5", "draw": i, "map": "mul_a", "a": r.uniform(1.001, 2.0), "x0": x0})
        elif v == 2:
            runs.append({"family": "M5", "draw": i, "map": "add_recip_x", "x0": abs(x0)})
        else:
            runs.append({"family": "M5", "draw": i, "map": "add_recip_n", "x0": x0})
    for i in range(DRAWS):              # round-robin over the two registered r ranges
        rr = r.uniform(3.0, 3.54) if i % 2 == 0 else r.uniform(3.545, 3.564)
        runs.append({"family": "M6", "draw": i, "map": "logistic", "r": rr, "x0": r.uniform(0.1, 0.9)})
    i = 0
    while i < DRAWS:                    # rejection sampling on the Lyapunov exponent
        rr = r.uniform(3.7, 4.0)
        lam = lyapunov(rr)
        x0 = r.uniform(0.1, 0.9)
        if lam > LYAP_MIN:
            runs.append({"family": "M7", "draw": i, "map": "logistic", "r": rr, "x0": x0, "lyapunov": lam})
            i += 1
    for i in range(DRAWS):              # sigma ratio round-robin; 10 noise seeds per draw
        p = lin_params(r, 0.1, 0.999)
        ratio = 1e-6 if i % 2 == 0 else 1e-3
        for k in range(M8_SEEDS):
            runs.append({"family": "M8", "draw": i, "seed_index": k, "map": "noisy_linear", **p,
                         "sigma": ratio * abs(p["L"]), "noise_seed": r.getrandbits(63)})
    for n, run in enumerate(runs):
        run["run_id"] = n
    return {"issue": 1990, "seed": SEED, "draws": DRAWS, "m8_seeds": M8_SEEDS,
            "noise_len": NOISE_LEN, "runs_per_arm": len(runs), "runs": runs}

def noise(seed):
    g = random.Random(seed)
    return [g.uniform(-1.0, 1.0) for _ in range(NOISE_LEN)]

if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--noise":
        import os
        m = build()
        h = hashlib.sha256()
        os.makedirs(sys.argv[2], exist_ok=True)
        for run in m["runs"]:
            if run["family"] != "M8":
                continue
            text = "\n".join(repr(u) for u in noise(run["noise_seed"])) + "\n"
            with open(os.path.join(sys.argv[2], "noise-%03d.txt" % run["run_id"]), "w") as f:
                f.write(text)
            h.update(text.encode())
        print(h.hexdigest())
    else:
        text = json.dumps(build(), sort_keys=True, indent=1) + "\n"
        with open(sys.argv[1], "w") as f:
            f.write(text)
        print(hashlib.sha256(text.encode()).hexdigest())
