#!/usr/bin/env python3
# Doc-example checker: every ```eigenscript block in the given Markdown
# files that is immediately followed by an ```output block is executed,
# and its stdout must match the output block EXACTLY (trailing whitespace
# stripped per line). This is what keeps docs/SPEC.md and
# docs/COMPARISON.md from drifting away from the implementation: a
# semantics change that isn't reflected in the spec fails the suite.
#
# Conventions:
#   ```eigenscript        runnable; checked against the next ```output
#   ```eigenscript skip   runnable syntax but deliberately not executed
#                         (nondeterministic, needs network, etc.)
#   ```output             expected stdout of the preceding block
#   fragments that aren't full programs use a plain ``` fence
#
# Usage: test_doc_examples.py [--list] file.md [file2.md ...]

import re
import subprocess
import sys
import os
import tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
EIGS = os.environ.get("EIGENSCRIPT", os.path.join(ROOT, "src", "eigenscript"))

PASS = 0
FAIL = 0
SKIP = 0

FENCE = re.compile(r"^```(\S*)\s*(\S*)\s*$")


def blocks(path):
    """Yield (lineno, info, args, text) for each fenced block."""
    with open(path) as f:
        lines = f.readlines()
    i = 0
    while i < len(lines):
        m = FENCE.match(lines[i])
        if m and m.group(1):
            start = i + 1
            j = start
            while j < len(lines) and not lines[j].startswith("```"):
                j += 1
            yield (i + 1, m.group(1), m.group(2), "".join(lines[start:j]))
            i = j + 1
        else:
            i += 1


def norm(s):
    return "\n".join(line.rstrip() for line in s.rstrip("\n").split("\n"))


def main():
    global PASS, FAIL, SKIP
    args = [a for a in sys.argv[1:] if a != "--list"]
    listing = "--list" in sys.argv

    for path in args:
        pending = None  # (lineno, code) awaiting an output block
        for lineno, info, arg, text in blocks(path):
            if info == "eigenscript":
                if arg == "skip":
                    SKIP += 1
                    pending = None
                    continue
                pending = (lineno, text)
            elif info == "output" and pending is not None:
                code_line, code = pending
                pending = None
                if listing:
                    print("would run: %s:%d" % (path, code_line))
                    continue
                with tempfile.NamedTemporaryFile(
                        "w", suffix=".eigs", delete=False) as tf:
                    tf.write(code)
                    tmp = tf.name
                try:
                    # Run with cwd = the temp script's directory so
                    # cwd-relative and script-relative paths coincide.
                    # (On macOS the Python tempdir is /var/folders/...,
                    # not /tmp — examples must not assume either.)
                    p = subprocess.run([os.path.abspath(EIGS), tmp],
                                       capture_output=True,
                                       text=True, timeout=20,
                                       stdin=subprocess.DEVNULL,
                                       cwd=os.path.dirname(tmp))
                    got = norm(p.stdout)
                    want = norm(text)
                    # Mirror run_all_tests.sh's rc_ok: a nonzero exit whose
                    # only failure signal is a LeakSanitizer report (the
                    # known closure-cycle env leaks under ASan builds) is
                    # tolerated; output must still match exactly.
                    rc_ok = (p.returncode == 0 or
                             "LeakSanitizer: detected memory leaks" in p.stderr)
                    if got == want and rc_ok:
                        PASS += 1
                        print("  PASS: %s:%d" % (os.path.basename(path), code_line))
                    else:
                        FAIL += 1
                        print("  FAIL: %s:%d (rc=%d)" % (path, code_line, p.returncode))
                        print("    --- expected ---")
                        for l in want.split("\n")[:8]:
                            print("    " + l)
                        print("    --- got ---")
                        for l in got.split("\n")[:8]:
                            print("    " + l)
                        if p.stderr.strip():
                            print("    --- stderr ---")
                            for l in p.stderr.strip().split("\n")[:4]:
                                print("    " + l)
                finally:
                    os.unlink(tmp)
            else:
                pending = None

    print("")
    print("Doc examples: %d passed, %d failed, %d skipped" % (PASS, FAIL, SKIP))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
