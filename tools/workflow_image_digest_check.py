#!/usr/bin/env python3
"""Reject literal workflow image references that are not SHA-256 pinned."""

import re
import subprocess
import sys
from pathlib import Path

DIGEST = re.compile(r"@sha256:[0-9a-f]{64}(?:[ #]|$)")
IMAGE = re.compile(r"^\s*image:\s*([^#\s]+)")


def workflow_files(arguments: list[str]) -> list[Path]:
    if arguments:
        return [Path(name) for name in arguments]
    result = subprocess.run(
        ["git", "ls-files", ".github/workflows/*.yml", ".github/workflows/*.yaml"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    return [Path(name) for name in result.stdout.splitlines()]


def violations(paths: list[Path]) -> list[str]:
    failures = []
    examined = 0
    for path in paths:
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            match = IMAGE.match(line)
            if not match:
                continue
            value = match.group(1).strip('"\'')
            if value.startswith("${{"):
                continue
            examined += 1
            if not DIGEST.search(value):
                failures.append(f"{path}:{line_number}: tag-only workflow image: {value}")
    if examined == 0:
        failures.append("examined 0 literal workflow images")
    return failures


def main() -> int:
    failures = violations(workflow_files(sys.argv[1:]))
    for failure in failures:
        print(f"FAIL: {failure}")
    if failures:
        return 1
    print("workflow-image-digests: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
