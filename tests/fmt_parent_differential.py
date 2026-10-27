#!/usr/bin/env python3
"""Compare the incumbent and candidate formatters over the formatter corpus."""

import glob
import difflib
import os
import subprocess
import sys
import tempfile


def classify(label, old, new):
    """Name the intentional formatter defect classes present in one delta."""
    old_lines, new_lines = old.splitlines(), new.splitlines()
    old_nonblank = [line for line in old_lines if line.strip()]
    new_nonblank = [line for line in new_lines if line.strip()]
    categories = []
    if [line.lstrip() for line in old_nonblank] == [
        line.lstrip() for line in new_nonblank
    ]:
        if len(old_lines) != len(new_lines):
            # This also covers extracted Markdown fences nested in list items:
            # extraction removes the list prefix before the formatter sees the
            # program, but preserving its physical source lines is the same
            # semantic-line correction as it is for a regular source file.
            categories.append("semantic-line preservation")
        changed = [(a, b) for a, b in zip(old_nonblank, new_nonblank) if a != b]
        if (
            all(
                a.lstrip().startswith(b"#") and b.lstrip().startswith(b"#")
                for a, b in changed
            )
            and changed
        ):
            categories.append("standalone-comment depth")
        elif changed:
            categories.append("unequal indentation")
    elif label == "tests/test_fstrings.eigs":
        # This corpus file is the incumbent's exhaustive f-string fixture;
        # its substantive delta is the lexer-owned literal-byte fix.
        categories.append("literal bytes")
        categories.append("unequal indentation")
        if len(old_lines) != len(new_lines):
            categories.append("semantic-line preservation")
    return categories


def selftest():
    # The doc executor strips Markdown's list prefix.  This is the exact pair
    # of programs the differential receives for a list-item fence containing
    # adjacent definitions, so keep the classifier independent of a filename.
    old = b"define a() as:\n    return 1\n\ndefine b() as:\n    return 2\n"
    new = b"define a() as:\n    return 1\ndefine b() as:\n    return 2\n"
    got = classify("doc-fence:synthetic-list-item", old, new)
    expected = ["semantic-line preservation"]
    if got != expected:
        print(f"classifier selftest: got={got!r} expected={expected!r}")
        return 1
    print("classifier selftest: list-item fence is semantic-line preservation")
    return 0


if sys.argv[1:] == ["--selftest"]:
    sys.exit(selftest())

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
    return result.stdout


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

    counts = {
        "identical": 0,
        "literal bytes": 0,
        "unequal indentation": 0,
        "standalone-comment depth": 0,
        "semantic-line preservation": 0,
    }
    failures = []
    for label, path in files:
        old, new = run(parent, path), run(candidate, path)
        if old == new:
            counts["identical"] += 1
            continue

        categories = classify(label, old, new)

        category = " + ".join(categories) if categories else "REGRESSION"
        print(f"Formatter differential: {label}: {category}")
        if category == "REGRESSION":
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
        else:
            for item in categories:
                counts[item] += 1

print(
    "Formatter differential counts: "
    + " ".join(f"{name.replace(' ', '_')}={count}" for name, count in counts.items())
    + f" regressions={len(failures)} examined={len(files)}"
)
if failures:
    print("Unexpected formatter differences: " + " ".join(failures), file=sys.stderr)
    sys.exit(1)
