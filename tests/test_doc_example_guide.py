#!/usr/bin/env python3
"""Keep the documentation-contributor guide aligned with the fence checker."""

import os
import subprocess
import sys
import tempfile


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUIDE = os.path.join(ROOT, "docs", "README.md")
CHECKER = os.path.join(ROOT, "tests", "test_doc_examples.py")


def fail(message):
    print("  FAIL: doc example guide " + message)
    return 1


def main():
    with open(GUIDE, encoding="utf-8") as source:
        guide = source.read()

    required = (
        "` ```eigenscript ` fenced blocks must be followed by an "
        "` ```output ` block",
        "` ```eigenscript fragment k=v ... `",
        "` ```eigenscript nocheck <reason> `",
        "[full fence grammar](../tests/test_doc_examples.py)",
    )
    for statement in required:
        if statement not in guide:
            return fail("does not teach %s" % statement)

    fixture = """# Supported fence forms

```eigenscript
print of "paired"
```
```output
paired
```

```eigenscript fragment name="reader"
print of name
```

```eigenscript nocheck requires an unavailable service
print of "not executed"
```
"""
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as target:
        target.write(fixture)
        fixture_path = target.name
    try:
        result = subprocess.run(
            [sys.executable, CHECKER, fixture_path],
            capture_output=True,
            text=True,
            cwd=ROOT,
            timeout=30,
        )
    finally:
        os.unlink(fixture_path)

    if result.returncode != 0:
        sys.stdout.write(result.stdout)
        sys.stdout.write(result.stderr)
        return fail("teaches forms that the checker rejects")
    if "2 checked, 2 passed, 0 failed, 1 skipped" not in result.stdout:
        sys.stdout.write(result.stdout)
        return fail("fixture did not exercise all three supported forms")

    print("  PASS: doc example guide teaches and verifies all three supported forms")
    return 0


if __name__ == "__main__":
    sys.exit(main())
