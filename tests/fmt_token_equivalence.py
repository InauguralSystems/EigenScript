#!/usr/bin/env python3
"""Prove that --fmt preserves lexer type/value/line streams."""

import glob
import os
import subprocess
import sys
import tempfile


def run(argv, **kwargs):
    return subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=20, **kwargs)


def main():
    eigs, root, doc_list = map(os.path.abspath, sys.argv[1:4])
    files = []
    for pattern in ("examples/*.eigs", "lib/*.eigs", "tests/*.eigs"):
        files.extend(sorted(glob.glob(os.path.join(root, pattern))))
    with open(doc_list, encoding="utf-8") as stream:
        files.extend(line.rstrip("\n") for line in stream if line.strip())

    examined = refused = failures = 0
    with tempfile.TemporaryDirectory(prefix=".fmt-token-", dir=root) as temp:
        formatted = os.path.join(temp, "formatted.eigs")
        for path in files:
            before = run([eigs, "--dump-tokens", path])
            fmt = run([eigs, "--fmt", path])
            if before.returncode:
                # Invalid source must still be refused; it never enters the
                # semantic population and --fmt must emit no replacement.
                refused += 1
                if fmt.returncode == 0 or fmt.stdout:
                    failures += 1
                    print(f"TOKEN FAIL: {path}: lexer rejection was not preserved")
                continue
            examined += 1
            if fmt.returncode:
                failures += 1
                print(f"TOKEN FAIL: {path}: formatter exited {fmt.returncode}")
                continue
            with open(formatted, "wb") as output:
                output.write(fmt.stdout)
            after = run([eigs, "--dump-tokens", formatted])
            if after.returncode or before.stdout != after.stdout:
                failures += 1
                a = before.stdout.splitlines()
                b = after.stdout.splitlines()
                at = next((n for n, pair in enumerate(zip(a, b), 1)
                           if pair[0] != pair[1]), min(len(a), len(b)) + 1)
                print(f"TOKEN FAIL: {path}: token stream differs at token {at}")
    print(f"Formatter token equivalence: examined={examined} refused={refused} failures={failures}")
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
