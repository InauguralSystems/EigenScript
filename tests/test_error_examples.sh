#!/bin/bash
# Error-example checker: every examples/errors/*.eigs declares its
# expected failure with a header comment
#     # expect-error: <substring of the error output>
# and must (a) exit nonzero and (b) print that substring. This keeps the
# "bad examples with error messages" corpus honest: if an error message
# is ever reworded or a rejected construct starts being accepted, this
# fails instead of the docs silently lying.
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
EIGS="$ROOT/src/eigenscript"

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
    out=$("$EIGS" "$f" </dev/null 2>&1)
    rc=$?
    if [ "$rc" = "0" ]; then
        echo "  FAIL: $name (expected nonzero exit, got 0)"
        FAIL=$((FAIL + 1))
    elif ! printf '%s' "$out" | grep -qF "$expected"; then
        echo "  FAIL: $name (missing expected message)"
        echo "    expected substring: $expected"
        printf '%s\n' "$out" | head -3 | sed 's/^/    got: /'
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
