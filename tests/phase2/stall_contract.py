#!/usr/bin/env python3
"""R31-4 through R31-9: bare loops stall on qualifying window signals.

Each subject is the final assignment in its loop. Plain bookkeeping must
not replace the global observer alias. The harmonic case is measured only:
its exit is a documented residual, not an acceptance threshold.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


# The lists of the three jitter cases.
JITTER_STEPS = [
    -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0, -1.0, 1.0, -1.0,
    1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, -1.0,
    1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, -1.0,
    -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, -1.0, -1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, 1.0,
    1.0, -1.0, 1.0, -1.0, -1.0, 1.0, -1.0, -1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, -1.0,
    1.0, 1.0, -1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0, -1.0, 1.0, -1.0, -1.0, 1.0,
    -1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, 1.0, -1.0, -1.0, 1.0, -1.0, 1.0,
    -1.0, 1.0, -1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, -1.0,
    1.0, 1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0,
    -1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, 1.0, -1.0, -1.0, 1.0,
    1.0, -1.0, -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, 1.0, 1.0,
    -1.0, 1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, -1.0, 1.0, -1.0, -1.0, 1.0, -1.0, -1.0,
    1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0,
    -1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0, 1.0, -1.0, -1.0, 1.0, -1.0, -1.0, 1.0, -1.0,
    1.0, -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, -1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, -1.0,
    1.0, -1.0, -1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, 1.0,
    -1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, -1.0, -1.0,
    1.0, 1.0, -1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0,
    -1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, -1.0,
    -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0, 1.0,
    -1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, -1.0, -1.0,
    1.0, 1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, 1.0, -1.0,
    -1.0, 1.0, -1.0, 1.0, -1.0, -1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, -1.0,
    1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0,
    -1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0,
    -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, 1.0, -1.0, 1.0, -1.0, 1.0, 1.0,
    -1.0, -1.0, 1.0, 1.0, -1.0, 1.0, -1.0, -1.0, 1.0, -1.0
]
JITTER_VALUES = [
    1000000.0, 999999.0, 1000000.0, 999999.0, 1000000.0, 999999.0, 1000000.0, 1000001.0,
    1000000.0, 1000001.0, 1000000.0, 1000001.0, 1000000.0, 999999.0, 1000000.0,
    999999.0, 1000000.0, 1000001.0, 1000000.0, 1000001.0, 1000000.0, 1000001.0,
    1000000.0, 1000001.0, 1000002.0, 1000001.0, 1000000.0, 1000001.0, 1000002.0,
    1000001.0, 1000000.0, 1000001.0, 1000000.0, 1000001.0, 1000002.0, 1000001.0,
    1000000.0, 1000001.0, 1000000.0, 999999.0, 1000000.0, 1000001.0, 1000000.0,
    999999.0, 1000000.0, 999999.0, 999998.0, 999999.0, 1000000.0, 999999.0, 999998.0,
    999999.0, 999998.0, 999997.0, 999998.0, 999997.0, 999996.0, 999997.0, 999998.0,
    999997.0, 999998.0, 999999.0, 999998.0, 999999.0, 999998.0, 999997.0, 999998.0,
    999997.0, 999996.0, 999997.0, 999996.0, 999995.0, 999996.0, 999997.0, 999996.0,
    999995.0, 999996.0, 999997.0, 999996.0, 999995.0, 999996.0, 999995.0, 999996.0,
    999995.0, 999996.0, 999995.0, 999994.0, 999995.0, 999994.0, 999993.0, 999994.0,
    999993.0, 999992.0, 999993.0, 999994.0, 999993.0, 999992.0, 999993.0, 999994.0,
    999993.0, 999994.0, 999993.0, 999992.0, 999993.0, 999992.0, 999993.0, 999992.0,
    999993.0, 999992.0, 999993.0, 999992.0, 999991.0, 999992.0, 999993.0, 999992.0,
    999993.0, 999994.0, 999993.0, 999992.0, 999993.0, 999992.0, 999993.0, 999994.0,
    999993.0, 999994.0, 999993.0, 999994.0, 999995.0, 999994.0, 999993.0, 999994.0,
    999993.0, 999994.0, 999993.0, 999994.0, 999993.0, 999992.0, 999993.0, 999992.0,
    999991.0, 999992.0, 999993.0, 999992.0, 999991.0, 999992.0, 999993.0, 999992.0,
    999993.0, 999992.0, 999991.0, 999992.0, 999993.0, 999992.0, 999991.0, 999992.0,
    999993.0, 999992.0, 999993.0, 999994.0, 999993.0, 999992.0, 999993.0, 999994.0,
    999993.0, 999994.0, 999995.0, 999994.0, 999995.0, 999994.0, 999995.0, 999996.0,
    999995.0, 999994.0, 999995.0, 999994.0, 999995.0, 999994.0, 999993.0, 999994.0,
    999993.0, 999992.0, 999993.0, 999994.0, 999993.0, 999992.0, 999993.0, 999994.0,
    999993.0, 999994.0, 999995.0, 999994.0, 999995.0, 999994.0, 999995.0, 999994.0,
    999995.0, 999994.0, 999993.0, 999994.0, 999993.0, 999994.0, 999995.0, 999994.0,
    999995.0, 999994.0, 999993.0, 999994.0, 999993.0, 999992.0, 999993.0, 999992.0,
    999993.0, 999992.0, 999993.0, 999994.0, 999993.0, 999994.0, 999995.0, 999994.0,
    999995.0, 999994.0, 999993.0, 999994.0, 999995.0, 999994.0, 999993.0, 999994.0,
    999993.0, 999992.0, 999993.0, 999992.0, 999991.0, 999992.0, 999993.0, 999992.0,
    999993.0, 999994.0, 999993.0, 999992.0, 999993.0, 999994.0, 999993.0, 999992.0,
    999993.0, 999994.0, 999993.0, 999992.0, 999993.0, 999992.0, 999993.0, 999994.0,
    999993.0, 999994.0, 999995.0, 999994.0, 999993.0, 999994.0, 999995.0, 999994.0,
    999993.0, 999994.0, 999993.0, 999994.0, 999995.0, 999994.0, 999993.0, 999994.0,
    999993.0, 999994.0, 999993.0, 999994.0, 999993.0, 999992.0, 999993.0, 999992.0,
    999993.0, 999992.0, 999993.0, 999992.0, 999991.0, 999992.0, 999993.0, 999992.0,
    999993.0, 999994.0, 999993.0, 999992.0, 999993.0, 999992.0, 999993.0, 999992.0,
    999993.0, 999994.0, 999993.0, 999992.0, 999993.0, 999992.0, 999993.0, 999994.0,
    999993.0, 999994.0, 999993.0, 999992.0, 999993.0, 999992.0, 999993.0, 999994.0,
    999993.0, 999992.0, 999993.0, 999994.0, 999993.0, 999994.0, 999995.0, 999994.0,
    999993.0, 999994.0, 999995.0, 999994.0, 999995.0, 999996.0, 999995.0, 999994.0,
    999995.0, 999994.0, 999993.0, 999994.0, 999995.0, 999994.0, 999995.0, 999994.0,
    999993.0, 999994.0, 999993.0, 999994.0, 999993.0, 999992.0, 999993.0, 999992.0,
    999991.0, 999992.0, 999993.0, 999992.0, 999991.0, 999992.0, 999991.0, 999992.0,
    999991.0, 999992.0, 999991.0, 999992.0, 999993.0, 999992.0, 999993.0, 999994.0,
    999993.0, 999994.0, 999993.0, 999994.0, 999995.0, 999994.0, 999993.0, 999994.0,
    999993.0, 999992.0, 999993.0, 999994.0, 999993.0, 999992.0, 999993.0, 999992.0,
    999993.0, 999994.0, 999993.0, 999992.0, 999993.0, 999992.0, 999993.0, 999994.0,
    999993.0, 999994.0, 999995.0, 999994.0, 999993.0, 999994.0, 999995.0, 999994.0,
    999995.0, 999994.0, 999995.0, 999996.0, 999995.0, 999994.0, 999995.0, 999996.0,
    999995.0, 999996.0, 999995.0, 999994.0, 999995.0, 999994.0
]


def _lit(xs):
    return "[" + ", ".join(repr(x) for x in xs) + "]"


CASES = {
    "doubling": ("x is 10.0\nx is 10.0", "x is x * 2.0"),
    "loop-exit": ("x is 1\nx is 100.0", "x is x * 2.0"),
    "additive": ("x is 1000000.0\nx is 1000000.0", "x is x + 200.0"),
    "damped": ("x is 1.0\nx is 1.0", "x is -0.99 * x"),
    "alternating": ("x is 1.0\nx is 1.0", "x is 0.0 - x"),
    "growing-alternating": ("x is 1.0\nx is 1.0", "x is -2.0 * x"),
    "infinite-alternating": ("x is 1e308 * 10.0\nx is 1e308 * 10.0", "x is 0.0 - x"),
    "nan-alternating": ("nan is f64_from_bits of 0x7ff8000000000000\nvals is [1.0, nan]\ni is 0\nx is 1.0", "i is 1 - i\nx is vals[i]"),
    "nan-prefix": ("n is 1000\nnan is f64_from_bits of 0x7ff8000000000000\nx is nan", "n is n + 1\nx is 1.0 / n"),
    "nan-newest": ("n is 1000\nnan is f64_from_bits of 0x7ff8000000000000\nx is 5.0", "n is n + 1\ny is 1.0 / n\nif n == 1005:\n    y is nan\nx is y"),
    "nan-period3": ("nan is f64_from_bits of 0x7ff8000000000000\nvals is [1.0, 2.0, nan]\ni is 0\nx is 1.0", "i is (i + 1) % 3\nx is vals[i]"),
    "nan-window-edge": ("nan is f64_from_bits of 0x7ff8000000000000\nvals is [512.0, 256.0, 128.0, 64.0, 32.0, 16.0, 8.0, 4.0, 2.0, 1.0, nan]\ni is 0\nx is 512.0", "i is (i + 1) % 11\nx is vals[i]"),
    "overflow-contracting": ("x is 1.7e308\nx is 1.7e308", "x is -0.995 * x"),
    "nan": ("x is f64_from_bits of 0x7ff8000000000000", "x is x"),
    "inf": ("x is 1e308\nx is 1e308", "x is x * 2.0"),
    "quiet": ("n is 1000\nx is 1.0 / n", "n is n + 1\nx is 1.0 / n"),
    "harmonic": ("n is 1\nx is 1.0 / n", "n is n + 1\nx is 1.0 / n"),
    "quiet-jitter": ("pat is " + _lit(JITTER_STEPS) + "\ni is 0\nx is 1000000.0\nx is 1000000.0",
                     "i is i + 1\nx is x + 994.0 * pat[i]"),
    "nan-prefix-jitter": ("vals is " + _lit(JITTER_VALUES) + "\nnan is f64_from_bits of 0x7ff8000000000000"
                          "\ni is 0\nx is nan", "i is i + 1\nx is vals[i]"),
    "nan-newest-jitter": ("vals is " + _lit(JITTER_VALUES) + "\nnan is f64_from_bits of 0x7ff8000000000000"
                          "\ni is 0\nx is 5.0",
                          "i is i + 1\ny is vals[i]\nif i == 5:\n    y is nan\nx is y"),
}
TIERS = {"off": {"EIGS_JIT_OFF": "1"}, "default": {},
         "osr": {"EIGS_JIT_OSR_THRESHOLD": "1"}, "trace": {"EIGS_TRACE": "1"}}


def program(case):
    init, step = CASES[case]
    body = "\n".join("    " + line for line in step.splitlines())
    return ("counter is 0\n" + init + "\nloop while not converged:  # lint: allow W014 -- x is assigned last\n"
            "    counter is counter + 1\n" + body + "\n"
            "print of [counter, __loop_exit__, report of x, converged of x]\n")


def correct(case, value):
    if case == "harmonic":
        return True  # R31-2 requests a measurement, without a requirement.
    count, reason, report, certified = value
    if case == "damped":
        return reason == "normal" and certified is True and count == 1454
    if case == "overflow-contracting":
        return reason == "normal" and certified is True and count == 144495
    # #2407: under the restored converged test (v0.47.0's relative-step band,
    # RULING R30R-2) these four loops certify before the stall counter can
    # reach 100. Each count is tools/reveal_restored_reference.py's first
    # converged read on the case's values (the additive runaway's one zero
    # step hides it from the raw same-sign guard; quiet's steps 1/(n+1) are
    # under 0.1%; the NaN leaves the window after 11 and after 16 iterations).
    if case == "additive":
        return count == 9 and reason == "normal" and certified is True
    if case == "quiet":
        return count == 10 and reason == "normal" and certified is True
    if case == "nan-prefix":
        return count == 11 and reason == "normal" and certified is True
    if case == "nan-newest":
        return count == 16 and reason == "normal" and certified is True
    if case == "nan-newest-jitter":
        return count == 101 and reason == "stalled" and certified is False
    if case in ("alternating", "growing-alternating", "infinite-alternating", "nan-alternating",
                "nan-period3", "nan-window-edge"):
        return 100 <= count <= 112 and reason == "stalled" and certified is False
    if case == "doubling":
        return 108 <= count <= 112 and reason == "stalled" and report == "diverging"
    if case == "loop-exit":
        return 100 <= count <= 112 and reason == "stalled" and report == "diverging"
    return count == 100 and reason == "stalled" and certified is False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binary", type=Path)
    ap.add_argument("--case", choices=CASES, action="append")
    ap.add_argument("--measure", action="store_true")
    ap.add_argument("--out", type=Path)
    ap.add_argument("--timeout", type=float, default=5)
    args = ap.parse_args()
    binary = str(args.binary.resolve())
    root = Path(__file__).resolve().parents[2]
    records = []
    failed = 0
    env = {k: v for k, v in os.environ.items() if not k.startswith("EIGS_")}
    with tempfile.TemporaryDirectory(prefix="stall-contract-") as tmp:
        for case in args.case or CASES:
            path = Path(tmp) / (case + ".eigs")
            path.write_text(program(case), encoding="utf-8")
            lint = subprocess.run([binary, "--lint", "--json", str(path)],
                                  cwd=root, env=env, capture_output=True, text=True)
            if lint.returncode:
                print("stall-contract: FAIL %s lint: %s" % (case, lint.stdout + lint.stderr))
                failed += 1
            for tier, extra in TIERS.items():
                tier_env = env | extra
                if tier == "trace":
                    tier_env["EIGS_TRACE"] = str(Path(tmp) / (case + ".eigst"))
                try:
                    result = subprocess.run([binary, str(path)], cwd=root, env=tier_env,
                                            capture_output=True, text=True, timeout=args.timeout)
                    rc, stdout, stderr = result.returncode, result.stdout, result.stderr
                except subprocess.TimeoutExpired:
                    rc, stdout, stderr = 124, "", "timeout"
                value = None
                if rc == 0:
                    try:
                        value = json.loads(stdout.strip())
                    except (ValueError, TypeError):
                        pass
                ok = rc == 0 and isinstance(value, list) and len(value) == 4
                if ok and not args.measure:
                    ok = correct(case, value)
                records.append(dict(case=case, tier=tier, rc=rc, value=value,
                                    stdout=stdout, stderr=stderr, ok=ok))
                print("stall-contract: %s %s tier=%s rc=%s value=%s" %
                      ("MEASURE" if args.measure else ("PASS" if ok else "FAIL"), case, tier, rc, value), flush=True)
                if not ok and not args.measure:
                    failed += 1
    if args.out:
        args.out.write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")
    print("stall-contract: measured=%d failures=%d" % (len(records), failed))
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
