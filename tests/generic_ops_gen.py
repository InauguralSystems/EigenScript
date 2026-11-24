#!/usr/bin/env python3
"""Generate and check the generic-operator cross-product oracle (#2512).

The compressed answers are executable output from main c35118f9, not a table
of answers maintained by hand.  ``--write`` is deliberately an explicit
review operation; normal suite runs only use ``--check``.
"""
import argparse
import gzip
import json
import os
import pathlib
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = pathlib.Path(__file__).resolve().parent
ORACLE = HERE / "generic_ops_expected.json.gz"
OPERANDS = [
    "0", "1", "-1", "7", "-3", "2", "63", "64", "-64",
    "140737488355327", "140737488355328", "-140737488355328", "-140737488355329",
    "9007199254740993", "9223372036854775807", "(-9223372036854775807 - 1)",
    "0.0", "(-0.0)", "2.5", "-2.5", "3.0", "-7.0", "1e308", "5e-324", "1e20",
    "9007199254740992.0", "9223372036854775808.0",
    "(f64_from_bits of 9221120237041090560)", "(f64_from_bits of 9218868437227405312)",
    "(f64_from_bits of -4503599627370496)", "true", "false", "null", '""', '"a"',
    '"abc"', '"b"', "[1, 2]", "[]", '{"a": 1}', "{}", "(buffer of 2)", "fnv",
    # Review-round additions: heterogeneous/nested containers, a multi-key
    # dict, digit text, and explicit signed integer and floating divisors.
    '[1, "a"]', "[[1], [2]]", '{"a": 1, "b": 2}', '"1"',
    # Distinct ints that round to the same double (2^53 and 2^53 + 1;
    # 2^63 - 2 and 2^63 - 1; their negatives): an int pair compared as
    # doubles answers wrong only on such a pair (plant D, round 6).
    "9007199254740992", "-9007199254740993", "9223372036854775806",
]
BIN = ["+", "-", "*", "/", "//", "%", "&", "|", "^", "<<", ">>", "==", "!=", "<", ">", "<=", ">="]
UN = ["-", "not", "~"]
STATES = ("unset", "0", "1")
SHAPES = ("module", "fn", "loop")

def setup():
    return "define fnv(x) as:\n    return x\nvals is [" + ", ".join(OPERANDS) + "]\n"

def emit(indent, tag, expr):
    return (f'{indent}try:\n{indent}    r is {expr}\n'
            f'{indent}    print of [{tag}, "OK", r, type of r, str of r]\n'
            f'{indent}catch e:\n{indent}    print of [{tag}, "ERR", e.kind, e.line, e.message]\n')

def program(shape):
    s, n = setup(), len(OPERANDS)
    if shape == "module":
        for i in range(n):
            s += f"v{i} is vals[{i}]\n"
        for op in BIN:
            for i in range(n):
                for j in range(n):
                    s += emit("", f'"b {op} {i} {j}"', f"v{i} {op} v{j}")
        for op in UN:
            for i in range(n):
                s += emit("", f'"u {op} {i}"', f"{op} v{i}")
        return s
    if shape == "fn":
        for k, op in enumerate(BIN):
            s += f"define op{k}(x, y) as:\n    return x {op} y\n"
        for k, op in enumerate(UN):
            s += f"define un{k}(x) as:\n    return {op} x\n"
    # A complete cross-product gives each operator site thousands of trips,
    # enough for the hot and OSR tiers to compile it.
    s += "for rep in range of 1:\n"
    for k, op in enumerate(BIN):
        s += f"    for i in range of {n}:\n        for j in range of {n}:\n"
        expr = f"op{k} of [vals[i], vals[j]]" if shape == "fn" else f"vals[i] {op} vals[j]"
        s += emit("            ", f'["b {op}", i, j]', expr)
    for k, op in enumerate(UN):
        s += f"    for i in range of {n}:\n"
        expr = f"un{k} of [vals[i]]" if shape == "fn" else f"{op} vals[i]"
        s += emit("        ", f'["u {op}", i]', expr)
    return s

def run(binary, shape, state):
    with tempfile.NamedTemporaryFile("w", suffix=".eigs", delete=False) as f:
        f.write(program(shape)); name = f.name
    env = os.environ.copy(); env.pop("EIGS_STRICT", None)
    if state != "unset": env["EIGS_STRICT"] = state
    try:
        p = subprocess.run([binary, name], env=env, text=True, capture_output=True)
    finally:
        os.unlink(name)
    if p.returncode:
        raise SystemExit(f"{shape}/{state}: binary exited {p.returncode}: {p.stderr[-2000:]}")
    return p.stdout

def collect(binary):
    keys = [(shape, state) for shape in SHAPES for state in STATES]
    # States are independent processes.  Running three at once keeps the
    # release section comfortably below its wall-time budget without making
    # an individual VM compete with more than two peers.
    with ThreadPoolExecutor(max_workers=3) as pool:
        raw = dict(zip(keys, pool.map(lambda key: run(binary, *key), keys)))
    # Alias identical strict-state streams rather than storing them repeatedly.
    streams, refs = [], {}
    for key, output in raw.items():
        try: index = streams.index(output)
        except ValueError: streams.append(output); index = len(streams) - 1
        refs["/".join(key)] = index
    return {"operands": OPERANDS, "operators": BIN + UN, "refs": refs, "streams": streams}

def first_difference(want, got):
    a, b = want.splitlines(), got.splitlines()
    for i in range(max(len(a), len(b))):
        x = a[i] if i < len(a) else "<missing>"; y = b[i] if i < len(b) else "<missing>"
        if x != y: return i + 1, x, y
    return 0, "", ""

def main():
    ap = argparse.ArgumentParser()
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", metavar="BASE_BINARY")
    mode.add_argument("--check", metavar="BINARY")
    mode.add_argument("--emit-c-header", metavar="PATH")
    args = ap.parse_args()
    if args.emit_c_header:
        out = pathlib.Path(args.emit_c_header)
        lines = ["/* Generated by tests/generic_ops_gen.py; do not edit. */",
                 "static const char *generic_operands[] = {"]
        lines.extend("    " + json.dumps(value) + "," for value in OPERANDS)
        lines.extend(["};", "#define GENERIC_OPERAND_COUNT (sizeof generic_operands / sizeof generic_operands[0])", ""])
        out.write_text("\n".join(lines))
        print(f"PASS: wrote {out} operands={len(OPERANDS)}")
        return
    binary = str(pathlib.Path(args.write or args.check).resolve())
    got = collect(binary)
    if args.write:
        with gzip.open(ORACLE, "wt", encoding="utf-8", compresslevel=9) as f:
            json.dump(got, f, separators=(",", ":"), sort_keys=True)
        print(f"PASS: wrote {ORACLE} ({ORACLE.stat().st_size} bytes)")
        return
    with gzip.open(ORACLE, "rt", encoding="utf-8") as f: want = json.load(f)
    cases = len(BIN) * len(OPERANDS) ** 2 + len(UN) * len(OPERANDS)
    for shape in SHAPES:
        for state in STATES:
            expected = want["streams"][want["refs"][f"{shape}/{state}"]]
            actual = got["streams"][got["refs"][f"{shape}/{state}"]]
            if actual != expected:
                line, old, new = first_difference(expected, actual)
                raise SystemExit(f"FAIL: {shape} strict={state} first differing case line {line}\n  main: {old}\n  candidate: {new}")
            print(f"PASS: generic operator cross-product shape={shape} strict={state} cases={cases}")

if __name__ == "__main__": main()
