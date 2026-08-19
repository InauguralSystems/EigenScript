#!/bin/sh
# Canonical sanitizer-output classifier for the shell test suite.
#
# WHY THIS FILE EXISTS: this decision — "is a nonzero exit tolerable because it
# is only a leak report?" — was open-coded at three sites and drifted apart at
# every one of them (#945/#953 in tests/test_doc_examples.py, then #969 in
# rc_ok, then #968 in test_sigusr1_dump.sh). Two of those drifts were silent:
# rc_ok returned SUCCESS for output carrying a heap-use-after-free as long as a
# leak line rode along, so a hard sanitizer failure was masked by the very gate
# meant to catch it. One source of truth, one corpus, one mutation-proven gate.
#
# The discriminator both bugs turned on: under ASan's integrated LeakSanitizer,
# a LEAK-ONLY run still prints
#     SUMMARY: AddressSanitizer: 16 byte(s) leaked in 1 allocation(s).
# A bare "AddressSanitizer" substring test reads that benign summary as a hard
# error (#968, false FAIL); no hard test at all lets a real one through (#969,
# false PASS). So benign leak summaries are removed BEFORE probing for hard
# diagnostics, and the probe runs BEFORE the leak marker is honored.
#
# Callers must not re-implement this. Source the file and call lsan_classify.
#
# EVERY PATTERN IS LOCAL TO THE FUNCTION, ON PURPOSE. rc_ok is `export -f`'d
# into child shells (run_all_tests.sh sections [99c]/[99d]), and `export -f`
# carries functions only — never the shell variables they read. When these
# patterns lived at file scope, an exported child got the function with EMPTY
# regexes, and `grep -E ""` matches every line: the residue filter deleted all
# output and the hard probe matched the empty result, so EVERYTHING classified
# as `hard`. Keeping the patterns inside the function makes it self-contained,
# so exporting the function is sufficient and cannot half-work.
#
# lsan_classify <captured-output>
#   returns 0  LEAK  — a leak report and nothing harder; tolerable
#   returns 1  HARD  — an ASan/UBSan/TSan/MSan diagnostic is present; never tolerable
#   returns 2  NONE  — no sanitizer report at all; a nonzero exit is a plain failure
#
# The input is the test program's COMBINED output, so it legitimately contains
# the program's own stdout as well. Patterns are therefore anchored to the
# report line shapes compiler-rt actually emits rather than matched loosely.

lsan_classify() {
    _lc_out="$1"

    # PRE-FILTER (§14: must be LOOSER than the matcher, and must actually
    # filter). Every branch of the hard probe below requires either a sanitizer
    # NAME — and all four contain the substring "Sanitizer" — or the literal
    # "runtime error: "; the leak marker requires "LeakSanitizer". So any input
    # that classifies as `leak` or `hard` necessarily contains one of these two
    # substrings, and anything without them is `none` by construction. This can
    # therefore never exclude wrongly.
    #
    # It exists because the classifier is now consulted UNCONDITIONALLY, on
    # every test program including the overwhelming majority that exit 0 with
    # ordinary output. Measured on this box: the full path costs ~36 ms per call
    # (three grep subprocesses plus two command substitutions), against ~0 for
    # the old `rc == 0` short-circuit. At the suite's call volume that is minutes
    # of pure process spawn, on a 4 GB box, under ASan — the shape that starves a
    # loaded runner into a failure that looks like infrastructure. This case is
    # pure shell pattern matching and spawns nothing.
    case "$_lc_out" in
        *Sanitizer*|*"runtime error: "*) ;;
        *) return 2 ;;
    esac

    # The sanitizer names that indicate a HARD failure when they head a report.
    # LeakSanitizer is deliberately absent here — "ERROR: LeakSanitizer:
    # detected memory leaks" is the tolerable case — but it IS present in
    # _lc_all below, where CHECK-failed and non-benign SUMMARY lines always
    # mean trouble whichever sanitizer emitted them.
    _lc_hard_names='AddressSanitizer|ThreadSanitizer|MemorySanitizer|UndefinedBehaviorSanitizer'
    _lc_all_names="$_lc_hard_names|LeakSanitizer"

    # Benign LSan summary line, in both the AddressSanitizer- and
    # LeakSanitizer-prefixed spellings compiler-rt uses. Deliberately narrow:
    # it must match the leak form and NOTHING else, because anything it matches
    # is removed before the hard probe runs.
    _lc_benign_summary='^(==[0-9]+==)?SUMMARY: (AddressSanitizer|LeakSanitizer): [0-9]+ byte\(s\) leaked in [0-9]+ allocation\(s\)\.[[:space:]]*$'

    # A hard diagnostic from any sanitizer. Six independent families, each with
    # at least one corpus fixture where it is the SOLE evidence (the gate's
    # probe-drop mutations prove that), so deleting any one of them goes red:
    #   1. ERROR:-headed reports   — ASan/TSan/MSan/UBSan
    #   2. WARNING:-headed reports — TSan races and MSan uninitialised reads
    #      head their reports with WARNING:, not ERROR:, and under
    #      print_summary=0 there is no SUMMARY: line, so this is all there is.
    #   3. FATAL:-headed messages  — a sanitizer that fails to START (e.g.
    #      "FATAL: ThreadSanitizer: unexpected memory mapping") emits neither
    #      ERROR: nor SUMMARY:. Without this, an unrunnable instrument is
    #      classified "none", i.e. reported as an ordinary test failure.
    #   4. DEADLYSIGNAL / CHECK failed — sanitizer internal aborts.
    #   5. runtime error:          — UBSan's per-check line. Matched across ALL
    #      UBSan kinds rather than a list of them; it is recoverable, so it can
    #      accompany exit code 0.
    #   6. SUMMARY: <name>:        — any summary that is not the benign leak
    #      form removed above.
    _lc_hard_probe="(^|[^A-Za-z])ERROR: ($_lc_hard_names)|(^|[^A-Za-z])WARNING: ($_lc_hard_names):|(^|[^A-Za-z])FATAL: ($_lc_all_names)|($_lc_all_names): ?(DEADLYSIGNAL|CHECK failed)|runtime error: |^(==[0-9]+==)?SUMMARY: ($_lc_all_names):"

    # The LeakSanitizer report header, with or without the ==pid==ERROR:
    # prefix. Anchored to a whole line so prose that merely mentions the marker
    # does not count as a report.
    _lc_marker='^(==[0-9]+==)?(ERROR: )?LeakSanitizer: detected memory leaks[[:space:]]*$'

    # LC_ALL=C and grep -a: a test program's own stdout can contain invalid
    # UTF-8 (the bytes/base64/deflate suites produce it). Without -a, GNU grep
    # switches to binary mode, prints "binary file matches" to the caller's
    # stderr and reports a whole-input match rather than a line match; without
    # LC_ALL=C the bracket expressions are locale-dependent. Both would make
    # this classification depend on the test program's payload.
    # MUTATE:BENIGN_FILTER — strip benign leak summaries so the generic
    # "SUMMARY: <sanitizer>:" hard probe below cannot match them (#968).
    _lc_residue=$(printf '%s\n' "$_lc_out" | LC_ALL=C grep -av -E "$_lc_benign_summary")

    # MUTATE:HARD_PROBE — a hard diagnostic outranks any leak report (#969).
    if printf '%s\n' "$_lc_residue" | LC_ALL=C grep -aq -E "$_lc_hard_probe"; then
        return 1
    fi

    if printf '%s\n' "$_lc_out" | LC_ALL=C grep -aq -E "$_lc_marker"; then
        return 0
    fi

    return 2
}

# Convenience wrapper: print the verdict name instead of returning it.
lsan_classify_name() {
    lsan_classify "$1"
    case $? in
        0) echo leak ;;
        1) echo hard ;;
        *) echo none ;;
    esac
}
