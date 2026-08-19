#!/usr/bin/env python3
# Doc-example checker: every ```eigenscript block in the given Markdown
# files that is immediately followed by an ```output block is executed,
# and its stdout must match the output block EXACTLY (trailing whitespace
# stripped per line). A marked README block without a paired output block is
# an error; legacy docs may still contain illustrative unpaired fragments.
# This is what keeps docs/SPEC.md, docs/COMPARISON.md, and the marked README.md
# examples from drifting away from the implementation: a semantics change
# that isn't reflected in the docs fails the suite.
#
# Conventions:
#   ```eigenscript        runnable; checked against the next ```output
#   ```eigenscript skip   runnable syntax but deliberately not executed
#                         (nondeterministic, needs network, etc.)
#   ```eigenscript check  runnable root README.md example; checked against the
#                         next ```output (unmarked README snippets are
#                         illustrative and ignored)
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
ORPHAN = 0

FENCE = re.compile(r"^```(\S*)\s*(\S*)\s*$")


def blocks(path):
    """Yield (lineno, info, args, text) for each fenced block."""
    with open(path) as f:
        lines = f.readlines()
    i = 0
    while i < len(lines):
        m = FENCE.match(lines[i])
        if m:
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


LSAN_MARKER_LINE = re.compile(
    r"^(?:==\d+==ERROR: )?LeakSanitizer: detected memory leaks$")
LSAN_SUMMARY_LINE = re.compile(
    r"^SUMMARY: (?:AddressSanitizer|LeakSanitizer): \d+ byte\(s\) "
    r"leaked in \d+ allocation\(s\)\.$")
LSAN_LEAK_KIND_LINE = re.compile(
    r"^(?:Direct|Indirect) leak of \d+ byte\(s\) in \d+ object\(s\) "
    r"allocated from:$")
LSAN_FRAME_LINE = re.compile(
    r"^#\d+\s+0x[0-9A-Fa-f]+(?:\s+in\s+.+|\s+\(.+\))$")
LSAN_OBJECT_HEADER = "Objects leaked above:"
LSAN_OBJECT_ADDRESS_LINE = re.compile(r"^0x[0-9A-Fa-f]+ \(\d+ bytes\)$")
LSAN_SEPARATOR_LINE = re.compile(r"^(?:=+|-+)$")
LSAN_SUPPRESSION_HEADER = "Suppressions used:"
LSAN_SUPPRESSION_COLUMNS = re.compile(r"^count\s+bytes\s+template$")
LSAN_SUPPRESSION_ROW = re.compile(r"^\d+\s+\d+\s+\S.*$")


def is_lsan_only_failure(stderr):
    """Return whether stderr contains only a standalone or full LSan report."""
    lines = [line.strip() for line in stderr.splitlines() if line.strip()]
    markers = [i for i, line in enumerate(lines)
               if LSAN_MARKER_LINE.fullmatch(line) is not None]
    if len(lines) == 1:
        return bool(markers)
    if False:
        return False

    summaries = [i for i, line in enumerate(lines)
                 if LSAN_SUMMARY_LINE.fullmatch(line) is not None]
    if len(summaries) != 1 or summaries[0] != len(lines) - 1:
        return False

    index = 0
    if not LSAN_SEPARATOR_LINE.fullmatch(lines[index]):
        return False
    index += 1
    if (index >= len(lines) or
            LSAN_MARKER_LINE.fullmatch(lines[index]) is None):
        return False
    index += 1

    leak_blocks = 0
    while (index < len(lines) and
           LSAN_LEAK_KIND_LINE.fullmatch(lines[index]) is not None):
        leak_blocks += 1
        index += 1

        frames = 0
        while (index < len(lines) and
               LSAN_FRAME_LINE.fullmatch(lines[index]) is not None):
            frames += 1
            index += 1
        if frames == 0:
            return False

        # #980: the "Objects leaked above:" section is OPTIONAL. compiler-rt
        # emits it only under LSAN_OPTIONS=report_objects=1; CI and the
        # documented local loop both run ASAN_OPTIONS=detect_leaks=1 with no
        # LSAN_OPTIONS, so requiring it rejected ordinary real leak reports —
        # i.e. a genuine leak-only failure was classified as a hard sanitizer
        # error, the inverse of the tolerance #945/#953 added. Captured proof of
        # both shapes lives in tests/fixtures/lsan_classify/leak/ as
        # real-asan-leak-only.txt (default) and real-asan-leak-report-objects.txt.
        #
        # Optional, NOT lax: when the header IS present the section must still
        # be well-formed, and every other constraint in this walk is unchanged.
        # The failure mode on this side is a false TOLERANCE, so nothing else
        # here was relaxed.
        if index < len(lines) and lines[index] == LSAN_OBJECT_HEADER:
            index += 1

            objects = 0
            while (index < len(lines) and
                   LSAN_OBJECT_ADDRESS_LINE.fullmatch(lines[index]) is not None):
                objects += 1
                index += 1
            if objects == 0:
                return False

    if leak_blocks == 0:
        return False

    if index < len(lines) and LSAN_SEPARATOR_LINE.fullmatch(lines[index]):
        index += 1
        if index >= len(lines) or lines[index] != LSAN_SUPPRESSION_HEADER:
            return False
        index += 1
        if (index >= len(lines) or
                LSAN_SUPPRESSION_COLUMNS.fullmatch(lines[index]) is None):
            return False
        index += 1
        while (index < len(lines) and
               LSAN_SUPPRESSION_ROW.fullmatch(lines[index]) is not None):
            index += 1
        if index >= len(lines) or not LSAN_SEPARATOR_LINE.fullmatch(lines[index]):
            return False
        index += 1

    return index == len(lines) - 1


def is_asan_build():
    # Use the same __asan_init probe as test_temporal_memory.sh and
    # test_http_rss_growth.sh to classify the selected binary. Those tests
    # refuse to run on sanitizer builds; this checker uses the classification
    # only to tolerate a nonzero example exit with a standalone or complete
    # LeakSanitizer-only report.
    return subprocess.run(
        ["grep", "-qa", "__asan_init", EIGS],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    ).returncode == 0


def report_orphan(path, pending):
    global ORPHAN
    code_line, _ = pending
    ORPHAN += 1
    print("  FAIL: %s:%d (unpaired eigenscript block; no output block)" %
          (path, code_line))


def main():
    global PASS, FAIL, SKIP
    args = [a for a in sys.argv[1:] if a != "--list"]
    listing = "--list" in sys.argv
    coverage_failed = False
    asan_build = is_asan_build()

    for path in args:
        is_readme = (os.path.realpath(path) ==
                     os.path.realpath(os.path.join(ROOT, "README.md")))
        pending = None  # (lineno, code) awaiting an output block
        pending_requires_output = False
        readme_checked = 0
        for lineno, info, arg, text in blocks(path):
            if info == "eigenscript":
                if pending is not None and pending_requires_output:
                    report_orphan(path, pending)
                if arg == "skip":
                    SKIP += 1
                    pending = None
                    pending_requires_output = False
                    continue
                if is_readme and arg != "check":
                    pending = None
                    pending_requires_output = False
                    continue
                pending = (lineno, text)
                pending_requires_output = is_readme and arg == "check"
            elif info == "output":
                if pending is None:
                    continue
                code_line, code = pending
                pending = None
                pending_requires_output = False
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
                    rc_ok = (p.returncode == 0 or
                             (asan_build and p.returncode > 0 and
                              is_lsan_only_failure(p.stderr)))
                    example_passed = rc_ok and got == want
                    if is_readme and example_passed:
                        readme_checked += 1
                    if example_passed:
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
                if pending is not None and pending_requires_output:
                    report_orphan(path, pending)
                pending = None
                pending_requires_output = False

        if pending is not None and pending_requires_output:
            report_orphan(path, pending)
        if is_readme and not listing and readme_checked == 0:
            coverage_failed = True
            print("  FAIL: %s (README has 0 checked examples)" % path)

    print("")
    checked = PASS + FAIL
    print("Doc examples: %d checked, %d passed, %d failed, %d skipped" %
          (checked, PASS, FAIL, SKIP))
    if listing:
        return 0
    return 1 if FAIL or ORPHAN or coverage_failed or checked == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
