#!/usr/bin/env python3
"""Compare the incumbent and candidate formatters over the formatter corpus."""

import glob
import concurrent.futures
import difflib
import os
import subprocess
import sys
import tempfile


parent, candidate, root = map(os.path.abspath, sys.argv[1:4])
os.chdir(root)


def run(binary, path):
    result = subprocess.run(
        [binary, "--fmt", path],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=20,
    )
    if result.returncode:
        raise RuntimeError(
            f"{path}: formatter exited {result.returncode}: "
            + result.stderr.decode(errors="replace")
        )
    output = result.stdout
    if os.environ.get("FMT_DIFFERENTIAL_PLANT_NORMALIZATION") and binary == candidate:
        output = output.replace(b'"a" + "b"', b'"a"+"b"')
    return output


files = []
for pattern in ("examples/*.eigs", "lib/*.eigs", "tests/*.eigs"):
    for path in sorted(glob.glob(pattern)):
        valid = subprocess.run(
            [candidate, "--lint", "--lint-level", "error", path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=20,
        )
        if valid.returncode == 0:
            files.append((path, path))

with tempfile.TemporaryDirectory(prefix="fmt-parent-diff-") as temp:
    docs = ["README.md", *sorted(glob.glob("docs/*.md")), "docs/llms.txt"]
    extracted = subprocess.run(
        [sys.executable, "tests/test_doc_examples.py", "--extract", temp, *docs],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=30,
    )
    if extracted.returncode:
        sys.stderr.write(extracted.stderr)
        sys.exit(extracted.returncode)
    for number, path in enumerate(extracted.stdout.splitlines(), 1):
        files.append((f"doc-fence:{number:04d}", path))
    probe = os.path.join(temp, "normalization.eigs")
    with open(probe, "wb") as stream:
        stream.write(b'print of "a"+"b"\n')
    files.append(("normalization-probe", probe))
    if os.environ.get("FMT_DIFFERENTIAL_PROBE_ONLY"):
        files = [("normalization-probe", probe)]

    identical = examined = 0
    failures = []

    def compare_file(item):
        label, path = item
        return label, path, run(parent, path), run(candidate, path)

    # Formatter processes are independent and the row has a strict 60-second
    # self-test budget (product-source triggers may not claim more).  Build the
    # incumbent once, then fan out only these read-only comparisons.
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        compared = pool.map(compare_file, files)
        for label, path, old, new in compared:
            examined += 1
            if label == "normalization-probe" and new != b'print of "a" + "b"\n':
                print(f"Formatter differential: {label}: REGRESSION")
                failures.append(label)
                continue
            if old == new:
                identical += 1
                continue
            print(f"Formatter differential: {label}: REGRESSION")
            failures.append(label)
            sys.stdout.buffer.writelines(
                difflib.diff_bytes(
                    difflib.unified_diff,
                    old.splitlines(keepends=True),
                    new.splitlines(keepends=True),
                    fromfile=b"parent",
                    tofile=b"branch",
                )
            )

assert examined == len(files) > 0

print(f"Formatter differential counts: identical={identical} "
      f"regressions={len(failures)} examined={examined}")
if failures:
    print("Unexpected formatter differences: " + " ".join(failures), file=sys.stderr)
    sys.exit(1)
