#!/usr/bin/env python3
"""The stores of the #2528 HOT and LOOP programs lie inside the native code (#2541).

For the indexes 0.0 and -2.0: the end of the compiled prefix (EIGS_JIT_DUMP_PREFIX)
is pinned and lies past the last OP_INDEX_SET of the function (EIGS_DUMP_BC), and
the compiled count and the stops (EIGS_JIT_STOPS) are pinned. With the int index 0
neither store compiles; those rows of #2528 are not covered here.
"""
import ast
import os
import pathlib
import re
import subprocess
import sys
import tempfile

EIGS = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).parents[1] / "src/eigenscript").resolve()
info = subprocess.run([str(EIGS), "--build-info"], stdout=subprocess.PIPE, text=True).stdout
if "jit-backend=x86-64" not in info.split():
    print("SKIP: JIT scan-end pins require a binary with the x86-64 JIT")
    raise SystemExit(0)

# The programs come from the other test's syntax tree: its body is not run, and
# the two cannot drift.
source_path = pathlib.Path(__file__).with_name("test_buffer_store_nonfinite_2528.py")
fixtures = {n.targets[0].id: ast.literal_eval(n.value)
            for n in ast.parse(source_path.read_text()).body
            if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id in ("HOT", "LOOP")}

TAIL = {"HOT": "try:\n    put of [b, 1e999]\ncatch e:\n    print of e.kind\n",
        "LOOP": "append of [xs, 1e999]\ntry:\n    fill of [b, xs, 401.0]\ncatch e:\n    print of e.kind\n"}
# (program, index, environment, function, its compiled prefixes, compiled count, stops)
OSR = {"EIGS_JIT_OSR_THRESHOLD": "1"}
CASES = [
    ("HOT", "0.0", {}, "put", [19], 1, [(1, "INT_ZERO")]),
    ("HOT", "-2.0", {}, "put", [22], 1, [(1, "INT_ZERO")]),
    ("LOOP", "0.0", OSR, "fill", [79], 2, [(2, "JUMP_BACK")]),
    ("LOOP", "-2.0", OSR, "fill", [82], 2, [(2, "JUMP_BACK")]),
]

examined = failed = 0
for program, index, extra, function, want_prefix, want_compiled, want_stops in CASES:
    examined += 1
    env = {k: v for k, v in os.environ.items() if not k.startswith("EIGS_")}
    env.update(extra, EIGS_JIT_STOPS="1", EIGS_JIT_DUMP_PREFIX=function, EIGS_DUMP_BC="1")
    with tempfile.NamedTemporaryFile("w", suffix=".eigs") as f:
        f.write(fixtures[program].format(index=index) + TAIL[program])
        f.flush()
        q = subprocess.run([str(EIGS), f.name], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    prefix = sorted({int(n) for n in re.findall(rf"chunk='{function}'.*?prefix=(\d+)", q.stderr)})
    code = re.search(r"^=== <module>\.fn\[0\].*?(?=^=== |\Z)", q.stderr, re.M | re.S)
    stores = [int(n) for n in re.findall(r"^\s*(\d+)\s+\S+\s+INDEX_SET\b", code.group(0) if code else "", re.M)]
    compiled = re.search(r"^compiled:\s+(\d+)$", q.stderr, re.M)
    compiled = int(compiled.group(1)) if compiled else None
    stops = [(int(n), op) for n, op in re.findall(r"^\s*(\d+)\s+([A-Z][A-Z0-9_]+)\s+\(", q.stderr, re.M)]
    ok = (q.returncode == 0 and q.stdout == "value\n" and prefix == want_prefix and stores
          and max(prefix) > max(stores) and compiled == want_compiled and stops == want_stops)
    failed += not ok
    print(f"{'PASS' if ok else 'FAIL'}: {program} index {index}: compiled={compiled} stops={stops} "
          f"prefix={prefix} stores={stores}")
    if not ok:
        print(f"  wanted compiled={want_compiled} stops={want_stops} prefix={want_prefix}, each store below the "
              f"last prefix, stdout 'value'; got rc={q.returncode} stdout={q.stdout!r}")
        print("  A compiler change that alters the opcodes of these functions also turns this red.")
        print("\n".join(line for line in q.stderr.splitlines() if "runtime error" in line or "Sanitizer" in line))
print(f"examined={examined} failures={failed}")
raise SystemExit(bool(failed) or examined == 0)
