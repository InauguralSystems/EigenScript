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

# #946: a fence may be indented, or nested inside a blockquote or list item.
# All of those are valid CommonMark and render normally on GitHub — but the
# old column-zero-only pattern could not see them, so such an example was
# never run and never compared, with no diagnostic. The document looked gated
# while part of it was not. Silence was the bug, not the missing coverage.
# #946: a fence may be indented, nested in a blockquote, or inside a list
# item, and may use tildes or more than three backticks. All of those are
# valid CommonMark and render normally on GitHub — the old column-zero-only
# pattern could see none of them, so such an example was never run, never
# compared, and never mentioned.
#
# Recognising MORE is only half the job. The first cut of this fix matched
# indentation and blockquotes but not list items, and a list-item fence then
# desynchronised the walk: its CLOSING fence was read as an OPENING one,
# every later info string shifted by one, and a plain top-level example that
# the old parser checked was silently dropped. Coverage went DOWN while the
# gate still printed exit 0. Hence the reporter below.
FENCE = re.compile(
    r"^(?P<prefix>[ \t]*(?:(?:[-*+]|\d+[.)])[ \t]+)?(?:>[ \t]*)*)"
    r"(?P<fence>`{3,}|~{3,})"
    r"[ \t]*(?P<info>[^\s`~]*)[ \t]*(?P<args>[^\s`~]*)[ \t]*$")

# The reporter. It must be looser than FENCE on EVERY axis it polices
# (mechanical-gates §12) — the first cut shared the prefix alphabet `[ \t>]`
# with FENCE and hardcoded exactly three backticks, so it could not fire on
# any shape FENCE could not open, which is precisely the set it existed to
# catch. It is therefore built independently: any leading run of whitespace,
# blockquote markers and list markers, then three or more backticks OR
# tildes, with no constraint on what follows.
FENCE_LOOSE = re.compile(r"^[ \t]*(?:[-*+]|\d+[.)])?[ \t>]*(?:`{3,}|~{3,})")

# Info strings we will act on. Anything else that opened a fence is reported
# rather than assumed harmless — a garbage info string (e.g. from a fence the
# regex mis-split) must not pass as "some other language's block".
KNOWN_INFO = ("eigenscript", "output", "")

UNSEEN_FENCES = []   # (path, lineno, raw, why) — reported by main(), never dropped


# RESIDUALS of the dedent, measured rather than assumed:
#
#  * Indentation is counted in CHARACTERS, not display columns. A fence
#    indented with a TAB whose body is indented with SPACES therefore
#    under-strips, leaving the example with spurious leading whitespace. That
#    degrades LOUDLY, not silently — the extracted program hits
#    "Parse error: unexpected indent" and the gate reports a mismatch
#    (verified: `   print of 1` exits 1). Not fixed because no document in the
#    repo mixes them; if one ever does, the failure names the file.
#  * A blank line inside a BLOCKQUOTED fence ends the blockquote for a
#    CommonMark renderer but not for this walk, so the gate can read slightly
#    more than a reader sees. Same direction: any divergence surfaces as a
#    failing example, never as a silent pass.


def _dedent(line, indent, depth):
    """Strip a fence's own prefix from one of its body lines.

    Removes at most `indent` leading whitespace characters and `depth`
    blockquote markers, so the example's OWN indentation survives intact —
    EigenScript is indentation-sensitive, and stripping more than the fence
    carried would silently rewrite the program under test.
    """
    k = 0
    while k < indent and k < len(line) and line[k] in " \t":
        k += 1
    s = line[k:]
    for _ in range(depth):
        s = s.lstrip(" \t")
        if s.startswith(">"):
            s = s[1:]
            if s[:1] in (" ", "\t"):
                s = s[1:]
    return s


def blocks(path):
    """Yield (lineno, info, args, text) for each fenced block."""
    with open(path) as f:
        lines = f.readlines()
    i = 0
    while i < len(lines):
        m = FENCE.match(lines[i])
        if m:
            prefix = m.group("prefix")
            marker = m.group("fence")
            depth = prefix.count(">")
            # A list marker's width indents the block's continuation lines,
            # so it counts as indentation for the dedent even though it is
            # not repeated on those lines.
            indent = len(prefix) if depth == 0 else (
                len(prefix) - len(prefix.lstrip(" \t")))
            info = m.group("info")
            start = i + 1
            j = start
            closed = False
            while j < len(lines):
                d = _dedent(lines[j], indent, depth).lstrip(" \t")
                if d.startswith(marker[0] * 3) and len(
                        d) - len(d.lstrip(marker[0])) >= len(marker):
                    closed = True
                    break
                j += 1
            if not closed:
                # An unterminated fence would otherwise swallow the rest of
                # the document, taking every later example with it.
                UNSEEN_FENCES.append(
                    (path, i + 1, lines[i].rstrip("\n"), "never closed"))
            elif info not in KNOWN_INFO:
                # Not an EigenScript example — but say so only for shapes we
                # could plausibly have mis-parsed, never for ordinary ```sh.
                if "`" in info or "~" in info:
                    UNSEEN_FENCES.append(
                        (path, i + 1, lines[i].rstrip("\n"),
                         "unreadable info string %r" % info))
            text = "".join(_dedent(l, indent, depth) for l in lines[start:j])
            yield (i + 1, info, m.group("args"), text)
            i = j + 1
        else:
            if FENCE_LOOSE.match(lines[i]):
                UNSEEN_FENCES.append(
                    (path, i + 1, lines[i].rstrip("\n"), "not recognised"))
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

    # #946: a fence the parser could not read is COVERAGE LOSS, and the whole
    # point of that issue is that it used to happen in silence. Report every
    # one and fail — an author who wrote an example that is never executed
    # should hear about it from the gate, not discover it when the example
    # rots. This is stricter than the rest of the suite deliberately: the
    # alternative is a document that reads as gated while part of it is not.
    unseen_failed = False
    if UNSEEN_FENCES and not listing:
        unseen_failed = True
        print("")
        for upath, ulineno, uraw, uwhy in UNSEEN_FENCES:
            print("  FAIL: %s:%d fence %s, so its block is UNCHECKED: %s"
                  % (upath, ulineno, uwhy, uraw.strip()))

    print("")
    checked = PASS + FAIL
    print("Doc examples: %d checked, %d passed, %d failed, %d skipped, "
          "%d unreadable fence(s)" %
          (checked, PASS, FAIL, SKIP, len(UNSEEN_FENCES)))
    if listing:
        return 0
    return 1 if (FAIL or ORPHAN or coverage_failed or unseen_failed
                 or checked == 0) else 0


def selftest():
    """#946: prove the parser sees the fence shapes it used to be blind to,
    and that it reports anything it still cannot read.

    A gate that silently measures less still prints OK, so each case here
    plants the exact shape and requires a specific count — "more than zero"
    is satisfied by a parser that found only the easy one.
    """
    import tempfile as _tf
    rc = 0
    NL = chr(10)

    def case(name, md, want_eigs, want_unseen, want_body=None):
        nonlocal rc
        del UNSEEN_FENCES[:]
        with _tf.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
            f.write(md)
            path = f.name
        try:
            got = [(ln, txt) for ln, info, a, txt in blocks(path)
                   if info == "eigenscript"]
            ok = (len(got) == want_eigs and len(UNSEEN_FENCES) == want_unseen)
            # Compare the WHOLE body, never just its first line. An
            # over-stripping dedent leaves line 1 intact and destroys the
            # indentation of line 2 — and EigenScript is indentation
            # sensitive, so that silently rewrites the program under test.
            # A first-line-only assertion certified exactly that fault when
            # it was planted (2026-08-19).
            if ok and want_body is not None:
                ok = got[0][1] == want_body
            if ok:
                print("  selftest ok: %s" % name)
            else:
                body = got[0][1] if got else None
                print("  SELFTEST FAIL: %s -- eigenscript=%d (want %d), "
                      "unreadable=%d (want %d), body=%r (want %r)"
                      % (name, len(got), want_eigs, len(UNSEEN_FENCES),
                         want_unseen, body, want_body))
                rc = 1
        finally:
            os.unlink(path)

    P = "print of 1" + NL
    case("plain top-level fence",
         "```eigenscript" + NL + "print of 1" + NL + "```" + NL, 1, 0, P)
    case("blockquoted fence",
         "> ```eigenscript" + NL + "> print of 1" + NL + "> ```" + NL,
         1, 0, P)
    case("indented fence",
         "  ```eigenscript" + NL + "  print of 1" + NL + "  ```" + NL,
         1, 0, P)
    case("indented fence keeps the example's OWN indentation",
         "  ```eigenscript" + NL + "  if 1 == 1:" + NL +
         "      print of 1" + NL + "  ```" + NL,
         1, 0, "if 1 == 1:" + NL + "    print of 1" + NL)
    case("nested blockquote",
         "> > ```eigenscript" + NL + "> > print of 1" + NL +
         "> > ```" + NL, 1, 0, P)
    # Two reports, both real: the opener FENCE cannot read, and the closing
    # fence it orphans — which then reads as an unterminated open. Reporting
    # the second is what stops that stray fence from silently swallowing the
    # rest of the document.
    case("unreadable fence is reported, not dropped",
         "```eigenscript three tokens here" + NL + "print of 1" + NL +
         "```" + NL, 0, 2)
    case("tilde fence",
         "~~~eigenscript" + NL + "print of 1" + NL + "~~~" + NL, 1, 0, P)
    case("list-item fence (its close must not read as an open)",
         "- ```eigenscript" + NL + "  print of 1" + NL + "  ```" + NL,
         1, 0, P)
    case("numbered list-item fence",
         "1. ```eigenscript" + NL + "   print of 1" + NL + "   ```" + NL,
         1, 0, P)
    case("four-backtick fence",
         "````eigenscript" + NL + "print of 1" + NL + "````" + NL, 1, 0, P)
    case("unterminated fence is reported, not swallowed to EOF",
         "```eigenscript" + NL + "print of 1" + NL, 1, 1, P)
    case("prose mentioning a fence mid-line is not a fence",
         "Write it as ```eigenscript to open a block." + NL, 0, 0)


    # The containment property, asserted directly rather than trusted.
    # FENCE_LOOSE exists to catch what FENCE cannot open, so every line FENCE
    # REJECTS but that a reader would call a fence must match FENCE_LOOSE. The
    # first cut of this fix failed exactly here: both patterns were built from
    # `[ \t>]` and three literal backticks, so the reporter was blind to the
    # same shapes the matcher was — looser on no axis at all
    # (mechanical-gates §12). A prose rule did not prevent that; this does.
    fenceish = [
        "```eigenscript", "~~~eigenscript", "````eigenscript",
        "  ```eigenscript", "\t```eigenscript", "> ```eigenscript",
        ">```eigenscript", "> > ```eigenscript", "- ```eigenscript",
        "* ```eigenscript", "+ ```eigenscript", "1. ```eigenscript",
        "1) ```eigenscript", "  - ```eigenscript", "```eigenscript a b c",
        "~~~~output", "- ~~~eigenscript",
    ]
    # Assert FENCE_LOOSE covers ALL of them, not merely the ones FENCE
    # currently rejects. Phrasing it as "whatever FENCE rejects" makes the
    # check vacuous the moment FENCE is good — measured: it examined ONE line
    # and passed with the original broken reporter still in place. Pinning
    # LOOSE independently means narrowing FENCE later can never outrun the
    # reporter, which is the only thing standing between a new fence shape
    # and silence.
    leaks = [ln for ln in fenceish if not FENCE_LOOSE.match(ln + "\n")]
    if leaks or len(fenceish) < 17:
        print("  SELFTEST FAIL: FENCE_LOOSE must match every fence-ish line "
              "independently of FENCE; missed %r (examined %d, floor 17)"
              % (leaks, len(fenceish)))
        rc = 1
    else:
        print("  selftest ok: the reporter covers every fence-ish line "
              "independently (%d shapes)" % len(fenceish))

    # blocks() finding a problem is worthless if main() does not ACT on it.
    # Nothing above drives main(), and the real doc set produces zero
    # UNSEEN_FENCES, so the whole report-and-fail path — the half of this fix
    # that delivers "reported, not dropped" — could be deleted with the suite
    # still green. Two mutants proved exactly that. This is its witness.
    def main_case(name, md, want_rc, want_text):
        nonlocal rc
        del UNSEEN_FENCES[:]
        with _tf.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
            f.write(md)
            path = f.name
        import io as _io
        import contextlib as _cl
        global PASS, FAIL, SKIP, ORPHAN
        saved = (sys.argv, PASS, FAIL, SKIP, ORPHAN)
        buf = _io.StringIO()
        try:
            # main() reads sys.argv and the module-level counters directly,
            # so the probe swaps both and restores them — a selftest that
            # left PASS/FAIL moved would corrupt any later run in-process.
            sys.argv = ["test_doc_examples.py", path]
            PASS = FAIL = SKIP = ORPHAN = 0
            with _cl.redirect_stdout(buf):
                got_rc = main()
        finally:
            sys.argv, PASS, FAIL, SKIP, ORPHAN = saved
            os.unlink(path)
            del UNSEEN_FENCES[:]
        out = buf.getvalue()
        if got_rc == want_rc and want_text in out:
            print("  selftest ok: %s" % name)
        else:
            print("  SELFTEST FAIL: %s -- rc=%r (want %r), text %r not in "
                  "output:%s" % (name, got_rc, want_rc, want_text, out))
            rc = 1

    # The document carries a PASSING example as well as the unreadable fence.
    # Without it `checked == 0` fails the run on its own and this row passes
    # off a neighbouring guard — measured: a mutant that reported the fence
    # but no longer FAILED on it survived exactly that way
    # (mechanical-gates §41).
    main_case("main() FAILS on an unreadable fence, and says which line",
              "```eigenscript" + NL + "print of 1" + NL + "```" + NL +
              "```output" + NL + "1" + NL + "```" + NL +
              "```eigenscript three tokens here" + NL + "print of 1" + NL +
              "```" + NL,
              1, "is UNCHECKED")
    # Control: a clean document must still pass through main() unharmed, or a
    # main() that always failed would score full marks on the row above.
    main_case("main() passes a clean document",
              "```eigenscript" + NL + "print of 1" + NL + "```" + NL +
              "```output" + NL + "1" + NL + "```" + NL,
              0, "1 checked")

    print("SELFTEST: %s" % ("all fence shapes recognised"
                            if rc == 0 else "FAILED"))
    return rc


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    sys.exit(main())
