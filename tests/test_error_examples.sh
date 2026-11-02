#!/bin/bash
# Error-example checker: every examples/errors/*.eigs declares its
# expected failure with a header comment
#     # expect-error: <substring of the error output>
# and must (a) exit nonzero and (b) print that substring. This keeps the
# "bad examples with error messages" corpus honest: if an error message
# is ever reworded or a rejected construct starts being accepted, this
# fails instead of the docs silently lying.
#
# Every example must exit exactly 1 (the language's error exit) and its output
# must carry no sanitizer report (#2306). "Nonzero" used to be enough, and 1 is
# also ASan's halt exit code, so a heap-use-after-free reported after the
# expected message passed. There is no tolerated-leak ledger in a child script,
# so a leak report fails here too.
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
EIGS="$ROOT/src/eigenscript"
. "$TESTS_DIR/lsan_classify.sh"

PASS=0
FAIL=0

for f in "$ROOT"/examples/errors/*.eigs; do
    name=$(basename "$f")
    expected=$(grep -m1 "^# expect-error:" "$f" | sed 's/^# expect-error: //')
    if [ -z "$expected" ]; then
        echo "  FAIL: $name (no '# expect-error:' header)"
        FAIL=$((FAIL + 1))
        continue
    fi
    # #407 residual: runtime-error cases also pin their caret position with
    #     # expect-caret: <exact caret line, from the pipe on>
    # so a column-attribution regression moves the caret and fails here.
    caret=$(grep -m1 "^# expect-caret:" "$f" | sed 's/^# expect-caret: //')
    # #732: cascade cases pin the NUMBER of "Parse error" lines with
    #     # expect-error-count: <n>
    # so a suppressed spurious follow-on error can't silently come back.
    errcount=$(grep -m1 "^# expect-error-count:" "$f" | sed 's/^# expect-error-count: //')
    out=$("$EIGS" "$f" </dev/null 2>&1)
    rc=$?
    san=$(lsan_classify_name "$out")
    if [ "$san" != none ]; then
        echo "  FAIL: $name (sanitizer report: $san, rc=$rc)"
        printf '%s\n' "$out" | grep -E "Sanitizer|runtime error: " | head -3 | sed 's/^/    got: /'
        FAIL=$((FAIL + 1))
    elif [ "$rc" != "1" ]; then
        echo "  FAIL: $name (expected exit 1, got $rc)"
        FAIL=$((FAIL + 1))
    elif ! printf '%s' "$out" | grep -qF "$expected"; then
        echo "  FAIL: $name (missing expected message)"
        echo "    expected substring: $expected"
        printf '%s\n' "$out" | head -3 | sed 's/^/    got: /'
        FAIL=$((FAIL + 1))
    elif [ -n "$errcount" ] && \
         [ "$(printf '%s\n' "$out" | grep -c 'Parse error')" != "$errcount" ]; then
        echo "  FAIL: $name (wrong parse-error count)"
        echo "    expected $errcount, got $(printf '%s\n' "$out" | grep -c 'Parse error')"
        printf '%s\n' "$out" | head -4 | sed 's/^/    got: /'
        FAIL=$((FAIL + 1))
    elif [ -n "$caret" ] && ! printf '%s' "$out" | grep -qF "$caret"; then
        echo "  FAIL: $name (caret not at the declared column)"
        echo "    expected caret line: $caret"
        printf '%s\n' "$out" | head -4 | sed 's/^/    got: /'
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    fi
done

echo ""
echo "Error examples: $PASS passed, $FAIL failed"
exit $((FAIL > 0))
