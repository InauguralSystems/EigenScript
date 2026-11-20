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


# #2407: the quiet clause on windows that do not jitter. The restored `stable`
# is never true of a jittering window, so a quiet clause that also consulted
# `stable` would pass every jitter case. Three cases stand against that:
#   additive-single  a quiet runaway from its first step (0.02% a step);
#                    `stable` is false throughout. Exactly 100.
#   additive-run-in  the same runaway after eleven shrinking steps of 0.94%
#                    down to 0.14% (RUN_IN). For the first nine iterations
#                    the window still holds some of them: `stable` is true
#                    and the last step is quiet. The rule counts those nine
#                    too: exactly 100, not 109.
#   monotone-decay   steps that shrink from 0.89% and stay above the quiet
#                    threshold through iteration 135; `stable` is true from
#                    the first full window and the rule must not count. It
#                    certifies at 145 (ten quiet steps, iterations 136..145).
RUN_IN = [1000000.0, 1009500.0, 1018500.0, 1026500.0, 1033500.0, 1039500.0,
          1044500.0, 1048500.0, 1051500.0, 1054000.0, 1056000.0, 1057500.0]


def _lit(xs):
    return "[" + ", ".join(repr(x) for x in xs) + "]"


CASES = {
    "int-mixed-window": ("vals is [10000000000000000, 10000000000000001]\ni is 0\nx is 10000000000000000.0", "i is 1 - i\nx is vals[i]"),
    "int-mixed-wrap": ("n is 0\nvals is [10000000000000000, 10000000000000001]\ni is 0\nx is 0.9", "n is n + 1\ny is 0.5 + (x - 0.5) * 0.5\nif n >= 10:\n    i is 1 - i\n    y is vals[i]\nif n >= 99:\n    y is 20000000000000000 + i\nif n == 101:\n    y is 20000000000000000.0\nx is y"),
    "int-overflow-one-inexact": ("a is 0 - 4600000000000000000\nb is a + 10000\nvals is [a, b]\ni is 0\nn is 0\nx is b\nx is a\nx is b\nx is a\nx is b\nx is a\nx is b\nx is a\nx is b\nx is a",
                                 "n is n + 1\ni is 1 - i\ny is vals[i]\nif n == 91:\n    y is 4600000000000000000\nif n == 92:\n    y is 0 - 4700000000000000000\nif n >= 93:\n    y is (0 - 4700000000000000000) + i\nx is y"),
    "int-stopped-boxed": ("n is 0\nx is 10000000000000000", "n is n + 1\ny is x\nif n < 20:\n    y is x + 1\nx is y"),
    "int-alternating-boxed": ("vals is [10000000000000000, 10000000000000001]\ni is 0\nx is 10000000000000000", "i is 1 - i\nx is vals[i]"),
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
    "quiet-jitter": ("pat is " + _lit(JITTER_STEPS) + "\ni is 0\nx is 1000000.0",
                     "i is i + 1\nx is x + 994.0 * pat[i]"),
    "nan-prefix-jitter": ("vals is " + _lit(JITTER_VALUES) + "\nnan is f64_from_bits of 0x7ff8000000000000"
                          "\ni is 0\nx is nan", "i is i + 1\nx is vals[i]"),
    "nan-newest-jitter": ("vals is " + _lit(JITTER_VALUES) + "\nnan is f64_from_bits of 0x7ff8000000000000"
                          "\ni is 0\nx is 5.0",
                          "i is i + 1\ny is vals[i]\nif i == 5:\n    y is nan\nx is y"),
    "additive-single": ("x is 1000000.0", "x is x + 200.0"),
    "additive-run-in": ("\n".join("x is %r" % v for v in RUN_IN), "x is x + 200.0"),
    "monotone-decay": ("x is 0.9", "x is 0.5 + (x - 0.5) * 0.98"),
    "quiet-jitter-small": ("pat is " + _lit(JITTER_STEPS) + "\ni is 0\nx is 0.0005",
                           "i is i + 1\nx is x + 9.997e-07 * pat[i]"),
    "nan-prefix-jitter-small": ("vals is " + _lit(JITTER_VALUES) + "\nnan is f64_from_bits of 0x7ff8000000000000"
                                "\ni is 0\nx is nan", "i is i + 1\nx is vals[i] * 5e-10"),
    "nan-newest-jitter-small": ("vals is " + _lit(JITTER_VALUES) + "\nnan is f64_from_bits of 0x7ff8000000000000"
                                "\ni is 0\nx is 5.0",
                                "i is i + 1\ny is vals[i] * 5e-10\nif i == 5:\n    y is nan\nx is y"),
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
    if case == "int-mixed-window":
        # The float-to-integer first step is inexact at ring index 0; the next nine
        # boxed-integer unit steps are exact.  At test 10 the mixed full window
        # hides unit motion below the double noise floor and converges.  A wrap
        # that substitutes index 10 for index 0 calls the window all-exact, so
        # the raw alternation prevents that verdict.
        return count == 10 and reason == "normal" and certified is True
    if case == "int-mixed-wrap":
        # Tests 1..9 damp and do not advance the stall counter.  Test 99's
        # exact integer jump is the last relative-window blocker: at test 109
        # it has just aged out, while test 101's float step and test 102's
        # return-to-integer step remain in ring indices 0 and 1.  Reading the
        # mixed window gives the double noise floor, hides the following unit
        # steps, and converges at 109.  Reading forward from index 8 instead
        # misses 0 and 1 and delays the verdict to the stall check at 110.
        return count == 109 and reason == "normal" and certified is True
    if case == "int-overflow-one-inexact":
        # One inexact step in a window of exact ones.  a = -4.6e18 and b = a + 10000
        # alternate (exact +/-10000 steps) through test 90; 91 is +4.6e18 (an exact
        # step of 9.2e18, inside int64); 92 is -4.7e18, whose subtraction overflows
        # int64, so it is the one inexact step; 93..100 alternate -4.7e18 + 1 and
        # -4.7e18 (exact +/-1).  After 100 the ring has head 9: the inexact step at
        # index 0, the other nine exact.
        # Exit: tests 1..90 and 93..100 are quiet (|rel| <= 2.2e-15 < dh_zero); 91
        # and 92 qualify as oscillating (the +/-10000 flips above the floor) with a
        # non-contracting amplitude.  `converged` is false at every test: through
        # 90 the all-exact window has floor 0 and its +/-10000 steps raw-oscillate;
        # from 91 the relative steps of 91 (2.0) and 92 (-1.98) are in the window,
        # above dh_zero, until test 101.  So the stall counter ends it at 100.
        # Report on the window read correctly: floor 4*eps*(1 + 4.7e18) = 4174.4,
        # since it is not all exact.  oscillating: no; the relative test sees one
        # flip above dh_zero (92/91); the raw test needs non-vanishing steps, and
        # the newest five are 1 <= floor; the bounded test counts reversals only
        # of steps above the floor, 91 and 92: one reversal, under 2.  diverging:
        # no, the raw steps vanish at the floor.  improving answers: the best
        # moved to -4.7e18 at 92 (since = 8 < 10), the eleven values are finite,
        # their steps are not all of one sign beyond tau, and they do not expand
        # (two mean crossings, but the newer half's largest deviation 8.5e17 is
        # under the older half's 8.4e18).  A window read as all exact has floor
        # 0: the bounded test then counts the eight +/-1 steps, nine reversals,
        # |net| = 1e17 <= 0.3 * path 1.85e19, and answers `oscillating` first.
        return count == 100 and reason == "stalled" and report == "improving" and certified is False
    if case == "int-stopped-boxed":
        # The first 19 exact +1 steps are raw-diverging even though their
        # relative size is below 0.1%; the zero step at iteration 20 makes
        # that raw test non-vanishing-false and `converged` ends the loop. A double window's
        # magnitude-scaled noise floor hides the raw steps and certifies at 10.
        return count == 20 and reason == "normal" and certified is True
    if case == "int-alternating-boxed":
        # Exact +/-1 steps keep the loop oscillating, so 100 qualifying
        # iterations end at the stall counter.  On the double route the
        # magnitude-scaled noise floor hides those sub-0.1% raw steps, allowing
        # the full ten-step relative window to certify instead.
        return count == 100 and reason == "stalled" and certified is False
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
    if case == "monotone-decay":
        return count == 145 and reason == "normal" and certified is True
    if case in ("nan-newest-jitter", "nan-newest-jitter-small"):
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
