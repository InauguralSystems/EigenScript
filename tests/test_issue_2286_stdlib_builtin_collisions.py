#!/usr/bin/env python3
"""Regression and gate for stdlib top-level definitions shadowing builtins."""
import argparse, json, re, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
DEFINE = re.compile(r"^define\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(|as:)", re.MULTILINE)

def collisions(root, binary):
    api = json.loads(subprocess.run([binary, "--api", "--json"], text=True, capture_output=True, check=True, timeout=10).stdout)
    builtins, found = set(api["builtins"]), []
    for source in sorted((root / "lib").glob("*.eigs")):
        found += [f"{source.relative_to(root)}:{name}" for name in DEFINE.findall(source.read_text()) if name in builtins]
    return found

def run_program(binary, source):
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "case.eigs"; path.write_text(source)
        return subprocess.run([binary, path], cwd=ROOT, text=True, capture_output=True, timeout=10)

def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--selftest", action="store_true"); args = parser.parse_args()
    binary = ROOT / "src" / "eigenscript"
    print(f"PLAN: {2 if args.selftest else 9}")
    clean = collisions(ROOT, binary)
    if clean:
        print("FAIL: stdlib collision gate: " + ", ".join(clean)); return 1
    print("PASS: stdlib collision gate clean control")
    if args.selftest:
        with tempfile.TemporaryDirectory() as td:
            fixture = Path(td); (fixture / "lib").mkdir()
            (fixture / "lib" / "plant.eigs").write_text("define len(x) as:\n    return 0\n")
            planted = collisions(fixture, binary)
        if planted != ["lib/plant.eigs:len"]:
            print(f"FAIL: planted len collision was not specifically detected: {planted}"); return 1
        print("PASS: planted top-level define len turns collision gate red"); return 0
    cases = {
        "complex.add": ("lib/complex.eigs", "add of [[1,2,3],[4,5,6]]"),
        "lab.values": ("lib/lab.eigs", 'values of {"a": 1}'),
        "math.abs": ("lib/math.eigs", "abs of -5"),
        "math.dot": ("lib/math.eigs", "dot of [(buffer of 0),(buffer of 0)]"),
        "stats.sum": ("lib/stats.eigs", "sum of [1,2,3]"),
        "stats.mean": ("lib/stats.eigs", "mean of [1,2,3]"),
        "string.join": ("lib/string.eigs", 'join of [["a","b"], ","]'),
        "ui.dispatch": ("lib/ui.eigs", "dispatch of [[null], 0, 4]"),
    }
    for label, (module, expression) in cases.items():
        result = run_program(binary, f"before is {expression}\nload_file of \"{module}\"\nafter is {expression}\nprint of (before == after)\n")
        if result.returncode or result.stdout.strip() != "true":
            print(f"FAIL: {label} changed builtin (rc={result.returncode}, out={result.stdout!r}, err={result.stderr!r})"); return 1
        print(f"PASS: loading {module} preserves builtin for {label}")
    return 0
if __name__ == "__main__": raise SystemExit(main())
