#!/usr/bin/env python3
"""Run the embedding provenance test with either CLI build layout."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
ROOT = Path(__file__).resolve().parent.parent
def select_variant(root, sanitize=False):
    cli = root / "src/eigenscript"
    cli.stat()
    variants = [p.parent.name for p in (root / "build").glob("*/eigenscript")
                if p.samefile(cli)]
    variant = variants[0] if len(variants) == 1 else ("asan" if sanitize else "release")
    return variant, len(variants)
def summary_fields(stdout):
    # Field split, not an anchored line: an added field is not "no summary".
    found = []
    for line in stdout.splitlines():
        if not line.startswith("embed_roads: checks="):
            continue
        fields = {}
        for part in line.split()[1:]:
            if "=" not in part:
                continue
            key, value = part.split("=", 1)
            fields[key] = value
        found.append(fields)
    return found
def run(binary, fixtures, *extra):
    try:
        result = subprocess.run([str(binary), str(fixtures), *extra], capture_output=True,
                                text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        return 1, f"embed_roads: FAIL: {error}\n"
    rows = summary_fields(result.stdout)
    good = False
    if result.returncode == 0 and not result.stderr and len(rows) == 1:
        row = rows[0]
        try:
            good = (int(row["checks"]) >= 20 and int(row["scope_checks"]) >= 12
                    and int(row["failures"]) == 0)
        except (KeyError, ValueError):
            good = False
    output = result.stdout + result.stderr
    if not good:
        output += (f"embed_roads: FAIL: child rc={result.returncode}, "
                   "expected clean exit and nonempty checks\n")
    return int(not good), output
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path)
    args = parser.parse_args()
    binary = args.binary
    if binary is None:
        try:
            variant, matches = select_variant(ROOT, bool(os.environ.get("ASAN_OPTIONS")))
        except OSError as error:
            print(f"embed_roads: FAIL: cannot inspect CLI variant: {error}")
            return 1
        print(f"embed_roads: build={variant} ({matches} matching CLI variants; " +
              ("matching objects)" if matches == 1 else "dedicated source build)"))
        build = subprocess.run(["make", "-s", "-C", str(ROOT), "embed-roads",
                                "ROAD_VARIANT=" + variant], capture_output=True, text=True)
        if build.returncode:
            print("embed_roads: FAIL: build failed\n" + build.stdout + build.stderr)
            return 1
        binary = ROOT / "build" / variant / "embed_roads"
    binary = binary.resolve()
    status, output = run(binary, ROOT / "tests/embed_roads")
    print(output, end="")
    return status
if __name__ == "__main__":
    raise SystemExit(main())
