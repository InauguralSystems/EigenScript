#!/usr/bin/env python3
"""Plant tests for workflow_image_digest_check.py."""

import subprocess
import sys
import tempfile
from pathlib import Path

CHECKER = Path(__file__).with_name("workflow_image_digest_check.py")
PIN = "postgres:16@sha256:" + "a" * 64


def run(contents: str) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as directory:
        fixture = Path(directory) / "fixture.yml"
        fixture.write_text(contents, encoding="utf-8")
        return subprocess.run(
            [sys.executable, str(CHECKER), str(fixture)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )


def main() -> int:
    if sys.argv[1:] != ["--selftest"]:
        print(f"usage: {Path(sys.argv[0]).name} --selftest", file=sys.stderr)
        return 2

    control = run(f"services:\n  db:\n    image: {PIN}\n")
    if control.returncode != 0:
        print(f"FAIL: clean digest-pinned control failed: {control.stdout.strip()}")
        return 1
    print("PASS: clean digest-pinned control stays green")

    planted = run("services:\n  db:\n    image: postgres:16\n")
    expected = "tag-only workflow image: postgres:16"
    if planted.returncode == 0 or expected not in planted.stdout:
        print(f"FAIL: tag-only plant was not specifically caught: {planted.stdout.strip()}")
        return 1
    print("PASS: planted image: postgres:16 turns the guard red with the exact violation")
    print("PLAN: 2")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
