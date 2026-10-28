#!/usr/bin/env python3
"""Frozen harness for the experiment registered in EigenScript issue #1990."""
import argparse, csv, hashlib, json, math, random, subprocess, sys
from pathlib import Path

from scipy.optimize import fixed_point

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SHUFFLE_SEED = "1990_2026_10_28_shuffle"
ARMS = ("STD-py", "STD-py-default", "STD-scipy", "INC-bare", "INC-named")
CONVERGING = {"M1", "M2", "M3", "M4", "M8"}


def step(run, x, iteration, noise=None):
    name = run["map"]
    if name == "linear":
        return run["L"] + run["a"] * (x - run["L"])
    if name == "newton_sqrt":
        return (x + run["c"] / x) / 2
    if name == "sin":
        return math.sin(x)
    if name == "x_over_1px":
        return x / (1 + x)
    if name == "add_c":
        return x + run["c"]
    if name == "mul_a":
        return run["a"] * x
    if name == "add_recip_x":
        return x + 1 / x
    if name == "add_recip_n":
        return x + 1 / (iteration + 1)
    if name == "logistic":
        return run["r"] * x * (1 - x)
    if name == "noisy_linear":
        return run["L"] + run["a"] * (x - run["L"]) + run["sigma"] * noise[iteration]
    raise AssertionError(name)


def python_arm(run, arm, noise, loose=False):
    x, iterations = run["x0"], 0
    if arm == "STD-scipy":
        last = [x]
        def f(value):
            i = last[1] if len(last) == 2 else 0
            value = step(run, float(value), i, noise)
            last[:] = [value, i + 1]
            return value
        try:
            x = float(fixed_point(f, x, xtol=1e-3, maxiter=10000, method="iteration"))
            return x, "converged", last[1]
        except RuntimeError:
            return last[0], "exhausted", last[1]
    rtol, atol = ((1e-1 if loose else 1e-3), 1e-6)
    if arm == "STD-py-default":
        rtol, atol = 1e-5, 1e-8
    for i in range(10000):
        nxt = step(run, x, i, noise)
        iterations = i + 1
        if abs(nxt - x) <= atol + rtol * abs(nxt):
            return nxt, "converged", iterations
        x = nxt
    return x, "exhausted", iterations


def eig_expr(run):
    name = run["map"]
    q = lambda v: repr(float(v))
    if name in ("linear", "noisy_linear"):
        extra = " + %s * noise[it - 1]" % q(run["sigma"]) if name == "noisy_linear" else ""
        return "%s + %s * (x - %s)%s" % (q(run["L"]), q(run["a"]), q(run["L"]), extra)
    if name == "newton_sqrt": return "(x + %s / x) / 2.0" % q(run["c"])
    if name == "sin": return "sin of x"
    if name == "x_over_1px": return "x / (1.0 + x)"
    if name == "add_c": return "x + %s" % q(run["c"])
    if name == "mul_a": return "%s * x" % q(run["a"])
    if name == "add_recip_x": return "x + 1.0 / x"
    if name == "add_recip_n": return "x + 1.0 / (it + 1.0)"
    if name == "logistic": return "%s * x * (1.0 - x)" % q(run["r"])
    raise AssertionError(name)


def incumbent(run, arm, binary, noise):
    noise_line = "noise is []"
    if noise is not None:
        # The JSON is made from, and checked against, the registered generated file.
        noise_line = "noise is json_decode of (read_text of %s)" % json.dumps(str(HERE / ".noise.json"))
        (HERE / ".noise.json").write_text(json.dumps(noise))
    condition = "not converged" if arm == "INC-bare" else "not (converged of x)"
    bound = 20000 if arm == "INC-bare" else 10000
    source = """define measured(n) as:
    x is n
    it is 0
    %s
    loop while %s:
        it is it + 1
        x is %s
        if it >= %d:
            break
    exit_name is "exhausted"
    observed_iterations is it
    if it < %d:
        exit_name is __loop_exit__
        observed_iterations is __loop_iterations__
    return [x, exit_name, observed_iterations, it]
print of (json_encode of (measured of %s))
""" % (noise_line, condition, eig_expr(run), bound, bound, repr(float(run["x0"])))
    got = subprocess.run([str(binary), "-e", source], check=True, text=True,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    vals = json.loads(got.stdout.strip().splitlines()[-1])
    reason = "exhausted" if vals[1] in ("stalled", "break", "exhausted") else "converged"
    return float(vals[0]), reason, int(vals[3])


def noise_for(run):
    if run["family"] != "M8": return None
    path = HERE / "noise" / ("noise-%03d.txt" % run["run_id"])
    return [float(v) for v in path.read_text().splitlines()]


def classify(run, value, reason):
    if run["family"] not in CONVERGING:
        return "EXIT-WRONG" if reason == "converged" else "EXHAUSTED"
    eps = 1e-3 * max(abs(run["L"]), 1e-3)
    bound = 10 * eps
    if run["family"] == "M8":
        bound = 10 * max(eps, run["sigma"] / (1 - abs(run["a"])))
    if reason == "exhausted": return "EXHAUSTED"
    return "EXIT-CORRECT" if abs(value - run["L"]) <= bound else "EXIT-WRONG"


def one(run, arm, binary, loose=False):
    noise = noise_for(run)
    if arm.startswith("STD"):
        value, reason, iterations = python_arm(run, arm, noise, loose)
    else:
        value, reason, iterations = incumbent(run, arm, binary, noise)
    outcome = classify(run, value, reason)
    eps = 1e-3 * max(abs(run.get("L", 0)), 1e-3) if "L" in run else None
    ignored_wrong = (run["family"] not in CONVERGING or
                     (eps is not None and abs(value - run["L"]) >
                      10 * (max(eps, run.get("sigma", 0) / (1 - abs(run.get("a", 0))))
                            if run["family"] == "M8" else eps)))
    params = {k: v for k, v in run.items() if k not in ("run_id", "family", "draw", "seed_index", "map")}
    return {"arm": arm, "run_id": run["run_id"], "family": run["family"], "draw": run["draw"],
            "seed_index": run.get("seed_index", ""), "map": run["map"],
            "map_parameters": json.dumps(params, sort_keys=True, separators=(",", ":")),
            "exit_value": repr(value), "exit_reason": reason, "iterations": iterations,
            "outcome": outcome, "exit_error_over_epsilon": "" if eps is None else abs(value-run["L"])/eps,
            "ignored_wrong": int(ignored_wrong), "harness_bound": 20000 if arm == "INC-bare" else ""}


def signature(rows):
    return [(r["run_id"], r["exit_value"], r["exit_reason"], r["iterations"], r["outcome"]) for r in rows]


def summarize(rows):
    byarm = {}
    for arm in ARMS:
        rr = [r for r in rows if r["arm"] == arm]
        fam = {f: sum(x["outcome"] == "EXIT-WRONG" for x in rr if x["family"] == f) /
                  sum(x["family"] == f for x in rr) for f in sorted({x["family"] for x in rr})}
        byarm[arm] = {"W": sum(x["outcome"] == "EXIT-WRONG" for x in rr)/len(rr), "W_family": fam,
                      "exhausted_converging": sum(x["outcome"] == "EXHAUSTED" for x in rr if x["family"] in CONVERGING) /
                      sum(x["family"] in CONVERGING for x in rr),
                      "W_ignored": sum(x["ignored_wrong"] for x in rr)/len(rr)}
    lookup = {(r["arm"], r["run_id"]): r for r in rows}
    for arm in ("INC-bare", "INC-named"):
        ratios = [lookup[(arm, i)]["iterations"] / lookup[("STD-py", i)]["iterations"]
                  for i in range(425) if lookup[(arm, i)]["outcome"] == "EXIT-CORRECT" and
                  lookup[("STD-py", i)]["outcome"] == "EXIT-CORRECT"]
        ratios.sort()
        byarm[arm]["median_iteration_ratio_to_STD-py"] = ratios[len(ratios)//2]
    b, n, s = byarm["INC-bare"], byarm["INC-named"], byarm["STD-py"]
    conditions = {"bare_W_parity": b["W"] <= s["W"] + .01,
                  "named_W_parity": n["W"] <= s["W"] + .01,
                  "bare_zero_wrong_M5_M7": all(b["W_family"][f] == 0 for f in ("M5", "M6", "M7")),
                  "iteration_ratio_at_most_1_5": all(byarm[a]["median_iteration_ratio_to_STD-py"] <= 1.5 for a in ("INC-bare", "INC-named")),
                  "bare_W_ignored_parity": b["W_ignored"] <= s["W_ignored"] + .01}
    return {"shuffle_seed": SHUFFLE_SEED, "arms": byarm, "decision_conditions": conditions,
            "verdict": "CLAIM-STANDS" if all(conditions.values()) else "CLAIM-REWRITE"}


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--binary", default=str(ROOT/"src/eigenscript")); args = ap.parse_args()
    binary = Path(args.binary).resolve()
    manifest = json.loads((HERE/"manifest.json").read_text()); runs = manifest["runs"]
    version = subprocess.check_output([str(binary), "--version"], text=True).strip()
    # Controls run before the shuffled measurement, exactly as registered.
    control = {}
    for arm in ARMS:
        a = [one(r, arm, binary) for r in runs]
        b = [one(r, arm, binary) for r in runs]
        control[arm] = signature(a) == signature(b)
    subset = [r for r in runs if r["family"] in ("M1", "M3")]
    normal = [one(r, "STD-py", binary) for r in subset]
    loose = [one(r, "STD-py", binary, True) for r in subset]
    w0 = sum(r["outcome"] == "EXIT-WRONG" for r in normal)/len(normal)
    w1 = sum(r["outcome"] == "EXIT-WRONG" for r in loose)/len(loose)
    controls = {"negative_identical": control, "positive_W_STD_py": w0, "positive_W_loose": w1,
                "positive_delta": w1-w0, "passed": all(control.values()) and w1 >= w0 + .10}
    (HERE/"results").mkdir(exist_ok=True)
    (HERE/"results"/"controls.json").write_text(json.dumps(controls, indent=2, sort_keys=True)+"\n")
    if not controls["passed"]:
        print("CONTROL FAILED", json.dumps(controls, sort_keys=True)); return 2
    order = [(a, r) for a in ARMS for r in runs]
    random.Random(SHUFFLE_SEED).shuffle(order)
    (HERE/"results"/"order.csv").write_text("sequence,arm,run_id\n" + "".join("%d,%s,%d\n"%(i,a,r["run_id"]) for i,(a,r) in enumerate(order)))
    rows = [one(r, a, binary) for a, r in order]
    fields = list(rows[0])
    for arm in ARMS:
        with (HERE/"results"/(arm+".csv")).open("w", newline="") as f:
            w=csv.DictWriter(f,fields,lineterminator="\n"); w.writeheader(); w.writerows(r for r in rows if r["arm"]==arm)
    summary=summarize(rows); summary["binary_version"]=version; summary["controls"]=controls
    (HERE/"results"/"summary.json").write_text(json.dumps(summary,indent=2,sort_keys=True)+"\n")
    print(json.dumps(summary,indent=2,sort_keys=True)); return 0


if __name__ == "__main__": sys.exit(main())
