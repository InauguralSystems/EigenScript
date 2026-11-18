#!/usr/bin/env python3
"""Deterministic, terminating EigenCore-0 program generator (#2018)."""
from __future__ import annotations

import argparse
import random
import sys

SEAMS = ("function_assignment", "local_shadow", "closure", "parameter_reassignment",
         "taped_builtin", "temporal_read", "history_wrap")


def program(seed: int) -> str:
    """Return one program.  Only this local PRNG influences the byte stream."""
    r = random.Random(seed)
    a, b = r.randint(-1000, 1000), r.randint(1, 40)
    builtin = r.choice(("random_int of [1, 17]", "read_line of []", 'env_get of ["REF_DIFF_MISSING"]'))
    seam_names = "function_assignment local_shadow closure parameter_reassignment temporal_read"
    if seed % 4 != 0:
        seam_names += " taped_builtin"
    lines = [f"# ref-diff seed: {seed}", f"# ref-diff: {seam_names}"]
    lines += [f"total is {a}", "define mutate(p) as:", "    p is p + 1", "    total is total + p",
              "    local total is p + 2", "    total is total + 1", "    return total",
              f"print of (mutate of {b})"]
    lines += ["define maker(start) as:", "    local value is start", "    define step(delta) as:",
              "        delta is delta + 1", "        return start + delta",
              "    return step", "counter is maker of 3", "print of (counter of 2)", "print of (counter of 3)"]
    if seed % 4 != 0:
        lines += [f"effect is {builtin}", "print of effect"]
    # One program in four deliberately crosses the fixed 256-entry window.
    count = 260 if seed % 4 == 0 else 3 + r.randrange(8)
    if count > 256:
        lines.append("# ref-diff: history_wrap")
    lines.append("history is 0")
    lines.extend(f"history is {i}" for i in range(1, count + 1))
    lines += ["age is when is history", "print of age"]
    # Keep producing the full temporal grammar even when a model revision does
    # not support it: classification, rather than generation, owns that scope.
    if seed % 5 == 0:
        lines += ["prior is prev of history", f"old is what is history when {max(1, count - 1)}",
                  "print of prior", "print of old"]
    # There is no recursion and no dynamically controlled loop.  All generated
    # integer operands are below 2000 (the history ordinal below 261), far from
    # the exact-integer boundary at 2^53.
    return "\n".join(lines) + "\n"


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("seed", type=int, nargs="?")
    p.add_argument("--count", type=int)
    args = p.parse_args()
    if args.count is not None:
        if args.count < 0:
            p.error("--count must be non-negative")
        for seed in range(1, args.count + 1):
            sys.stdout.write(f"@@ program {seed}\n{program(seed)}")
    elif args.seed is not None:
        sys.stdout.write(program(args.seed))
    else:
        p.error("give SEED or --count N")


if __name__ == "__main__":
    main()
