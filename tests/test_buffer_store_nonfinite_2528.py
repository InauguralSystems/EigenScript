#!/usr/bin/env python3
"""A buffer store refuses inf, -inf and nan whatever the index's type (#2528).

Each case is its own program, run with EIGS_STRICT unset, 0 and 1 and with the
JIT on and off. A refused store raises `value` and leaves the old cell.
"""
import os, pathlib, platform, re, subprocess, sys, tempfile
EIGS = pathlib.Path(sys.argv[1]).resolve()
REFUSED = '["value", "buffer store: expected a finite number"]'
# A literal reaches the store as an unboxed double (the C and JIT fast paths); a
# builtin's answer is boxed (the generic arm). Arithmetic traps under EIGS_STRICT=1,
# so only the literal inf and the boxed values exist in that state.
ALL, NOT_STRICT = (None, "0", "1"), (None, "0")
VALUES = [("inf", "1e999", ALL), ("-inf", "-1e999", NOT_STRICT), ("nan", "1e999 - 1e999", NOT_STRICT),
          ("inf", "f64_from_bits of 9218868437227405312", ALL),
          ("-inf", "f64_from_bits of -4503599627370496", ALL),
          ("nan", "f64_from_bits of 9221120237041090560", ALL)]
INDEXES = ["0", "0.0", "-2.0"]
FINITE = ["1.5", "-0.25", "3", "0.0", "1.7976931348623157e308", "-1.7976931348623157e308", "5e-324"]
# 400 finite stores by a function make it hot; the store under test is call 401.
HOT = "define put(b, x) as:\n    b[{index}] is x\n    return 0\nb is buf_from_list of ([5.0, 6.0])\nfor k in range of 400:\n    put of [b, 7.5]\n"
failures = rows = 0

def run(root, source, strict, jit):
    env = {k: v for k, v in os.environ.items()
           if k not in ("EIGS_STRICT", "EIGS_JIT_OFF", "EIGS_TRACE", "EIGS_REPLAY")}
    if strict is not None: env["EIGS_STRICT"] = strict
    if not jit: env["EIGS_JIT_OFF"] = "1"
    program = root / "case.eigs"
    program.write_text(source)
    q = subprocess.run([str(EIGS), str(program)], env=env, stdin=subprocess.DEVNULL,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return q.returncode, q.stdout, q.stderr

def check(root, name, source, want, states=ALL):
    global failures, rows
    for strict in states:
        for jit in (True, False):
            rows += 1
            got = run(root, source, strict, jit)
            if got != (0, want, ""):
                failures += 1
                print(f"FAIL: {name} strict={strict or 'unset'} jit={'on' if jit else 'off'}: {got!r} wanted {want!r}")

with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    for shown, value, states in VALUES:
        # The value is what its name says, so a refusal cannot be a wrong input.
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
    for value in FINITE:
        for index in INDEXES:
            check(root, f"finite hot b[{index}] is {value}",
                  HOT.format(index=index) + f"put of [b, {value}]\nprint of (b[0] == {value})\nprint of b[1]\n",
                  "true\n6.0\n")
    # On x86-64 the hot cases above are native code, not only interpreted.
    if platform.machine() in ("x86_64", "AMD64") and sys.platform == "linux":
        rows += 1
        program = root / "case.eigs"
        program.write_text(HOT.format(index="0.0"))
        q = subprocess.run([str(EIGS), str(program)], env=dict(os.environ, EIGS_JIT_STATS="1"), stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if not re.search(r"\bcompiled=[1-9]", q.stdout):
            failures += 1
            print(f"FAIL: the hot store did not compile: {q.stdout!r}")
    else:
        print("SKIP: native-code row (no x86-64 Linux JIT here)")
print(f"ROWS: buffer store nonfinite examined={rows} failures={failures}")
sys.exit(1 if failures else 0)
