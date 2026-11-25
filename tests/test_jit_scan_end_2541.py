#!/usr/bin/env python3
"""Pin the native-prefix scan ends of the #2528 HOT and LOOP fixtures."""
import ast
import os
import pathlib
import platform
import re
import subprocess
import sys
import tempfile

EIGS = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).parents[1] / "src/eigenscript").resolve()
if platform.system() != "Linux" or platform.machine() not in ("x86_64", "AMD64"):
    print("SKIP: JIT scan-end pins require x86-64 Linux")
    raise SystemExit(0)

# Read the assignments from the existing test's syntax tree: this deliberately
# cannot execute its test body, and the fixtures therefore cannot drift.
source_path = pathlib.Path(__file__).with_name("test_buffer_store_nonfinite_2528.py")
tree = ast.parse(source_path.read_text(), filename=str(source_path))
fixtures = {}
for node in tree.body:
    if not isinstance(node, ast.Assign) or len(node.targets) != 1 or not isinstance(node.targets[0], ast.Name):
        continue
    if node.targets[0].id in ("HOT", "LOOP"):
        fixtures[node.targets[0].id] = ast.literal_eval(node.value)
if set(fixtures) != {"HOT", "LOOP"}:
    print(f"FAIL: could not extract HOT and LOOP from {source_path}")
    raise SystemExit(1)

# Index 0.0: with the int index 0 the function's compiled prefix is empty.
cases = {
    "function": (fixtures["HOT"].format(index="0.0") +
                 "try:\n    put of [b, 1e999]\ncatch e:\n    print of e.kind\n",
                 {}, 1, [(1, "INT_ZERO")]),
    "loop": (fixtures["LOOP"].format(index="0.0") +
             "append of [xs, 1e999]\ntry:\n    fill of [b, xs, 401.0]\ncatch e:\n    print of e.kind\n",
             {"EIGS_JIT_OSR_THRESHOLD": "1"}, 2, [(2, "JUMP_BACK")]),
}

failed = 0
for name, (program, extra, want_compiled, want_stops) in cases.items():
    with tempfile.NamedTemporaryFile("w", suffix=".eigs") as f:
        f.write(program); f.flush()
        env = {k: v for k, v in os.environ.items() if not k.startswith("EIGS_")}; env.update(extra); env["EIGS_JIT_STOPS"] = "1"
        q = subprocess.run([str(EIGS), f.name], env=env, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    compiled_m = re.search(r"^compiled:\s+(\d+)$", q.stderr, re.M)
    stops = [(int(n), op) for n, op in re.findall(r"^\s+(\d+)\s+([A-Z][A-Z0-9_<>-]+)\s+\(", q.stderr, re.M)]
    got_compiled = int(compiled_m.group(1)) if compiled_m else None
    if q.returncode == 0 and q.stdout == "value\n" and got_compiled == want_compiled and stops == want_stops:
        print(f"PASS: {name} scan end compiled={got_compiled} stops={stops}")
    else:
        failed += 1
        print(f"FAIL: {name} scan end: compiled={got_compiled}, stops seen={stops}; "
              f"wanted compiled={want_compiled}, stops={want_stops}. A compiler change "
              "that alters opcodes after the store also changes this boundary.")
        if q.returncode: print(f"  return code: {q.returncode}")
print(f"examined=2 failures={failed}")
raise SystemExit(bool(failed))
