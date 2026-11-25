#!/usr/bin/env python3
"""Buffer stores of inf, -inf and nan at index 0, 0.0 and -2.0 are refused (#2528).

Each case is its own program, run with the JIT on and off, in the EIGS_STRICT
states listed for its value (unset, 0 and 1 where none is listed). A refused
non-finite store raises `value` and leaves the old cell.
"""
import os, pathlib, subprocess, sys, tempfile
EIGS = pathlib.Path(sys.argv[1]).resolve()
REFUSED = '["value", "buffer store: expected a finite number"]'
# Arithmetic traps under EIGS_STRICT=1, so -1e999 and 1e999 - 1e999 are not run in
# that state.
ALL, NOT_STRICT = (None, "0", "1"), (None, "0")
VALUES = [("inf", "1e999", ALL), ("-inf", "-1e999", NOT_STRICT), ("nan", "1e999 - 1e999", NOT_STRICT),
          ("inf", "f64_from_bits of 9218868437227405312", ALL),
          ("-inf", "f64_from_bits of -4503599627370496", ALL),
          ("nan", "f64_from_bits of 9221120237041090560", ALL)]
INDEXES = ["0", "0.0", "-2.0"]
FINITE = ["1.5", "-0.25", "3", "0.0", "1.7976931348623157e308", "-1.7976931348623157e308", "5e-324"]
# 400 stores of 7.5 by a function; the store under test is call 401.
HOT = "define put(b, x) as:\n    b[{index}] is x\n    return 0\nb is buf_from_list of ([5.0, 6.0])\nfor k in range of 400:\n    put of [b, 7.5]\n"
# The store inside a loop, run with EIGS_JIT_OSR_THRESHOLD=1; the store under test
# is iteration 401.
LOOP = ("define fill(b, xs, n) as:\n    k is 0.0\n    loop while k < n:\n        b[{index}] is xs[k]\n        k is k + 1.0\n    return 0\n"
        "b is buf_from_list of ([5.0, 6.0])\nxs is []\nfor k in range of 400:\n    append of [xs, 7.5]\n")
OSR = {"EIGS_JIT_OSR_THRESHOLD": "1"}
failures = rows = 0

def run(root, source, strict, jit, extra=None):
    env = {k: v for k, v in os.environ.items()
           if k not in ("EIGS_STRICT", "EIGS_JIT_OFF", "EIGS_TRACE", "EIGS_REPLAY")}
    if extra: env.update(extra)
    if strict is not None: env["EIGS_STRICT"] = strict
    if not jit: env["EIGS_JIT_OFF"] = "1"
    program = root / "case.eigs"
    program.write_text(source)
    q = subprocess.run([str(EIGS), str(program)], env=env, stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return q.returncode, q.stdout, q.stderr

def check(root, name, source, want, states=ALL, extra=None):
    global failures, rows
    for strict in states:
        for jit in (True, False):
            rows += 1
            got = run(root, source, strict, jit, extra)
            if got != (0, want, ""):
                failures += 1
                print(f"FAIL: {name} strict={strict or 'unset'} jit={'on' if jit else 'off'}: {got!r} wanted {want!r}")

with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    for shown, value, states in VALUES:
        # Each value prints as its name.
        check(root, f"{value} is {shown}", f"print of ({value})\n", shown + "\n", states)
        for index in INDEXES:
            check(root, f"b[{index}] is {value}",
                  f"b is buf_from_list of ([5.0, 6.0])\ntry:\n    b[{index}] is ({value})\n    print of \"stored\"\n"
                  f"catch e:\n    print of [e.kind, e.message]\nprint of [b[0], b[1]]\n",
                  REFUSED + "\n[5.0, 6.0]\n", states)
            check(root, f"hot b[{index}] is {value}",
                  HOT.format(index=index) + f"try:\n    put of [b, {value}]\n    print of \"stored\"\n"
                  f"catch e:\n    print of [e.kind, e.message]\nprint of [b[0], b[1]]\n",
                  REFUSED + "\n[7.5, 6.0]\n", states)
    # The message names the bad index (0.5, 1e999, 2.0) for the values 1.5 and 1e999.
    for value in ("1.5", "1e999"):
        for index, message in (("0.5", "index must be an integer, got 0.5"), ("1e999", "index must be an integer, got inf"),
                               ("2.0", "buffer index 2.0 out of range (length 2)")):
            for name, source in (("", "b is buf_from_list of ([5.0, 6.0])\ntry:\n    b[{i}] is {v}\n"),
                                 ("hot ", HOT.replace("(b, x)", "(b, x, j)").replace("[{index}]", "[j]").replace("[b, 7.5]", "[b, 7.5, 0.0]") + "try:\n    put of [b, {v}, {i}]\n")):
                check(root, f"{name}b[{index}] is {value} names the index",
                      source.format(i=index, v=value) + "catch e:\n    print of e.message\nprint of b[1]\n", message + "\n6.0\n")
    for shown, value, states in VALUES:
        for index in INDEXES:
            check(root, f"loop b[{index}] is {value}",
                  LOOP.format(index=index) + f"append of [xs, {value}]\ntry:\n    fill of [b, xs, 401.0]\n    print of \"stored\"\n"
                  f"catch e:\n    print of [e.kind, e.message]\nprint of [b[0], b[1]]\n",
                  REFUSED + "\n[7.5, 6.0]\n", states, OSR)
    for value in FINITE:
        for index in INDEXES:
            check(root, f"finite hot b[{index}] is {value}",
                  HOT.format(index=index) + f"put of [b, {value}]\nprint of (b[0] == {value})\nprint of b[1]\n",
                  "true\n6.0\n")
print(f"ROWS: buffer store nonfinite examined={rows} failures={failures}")
sys.exit(1 if failures else 0)
