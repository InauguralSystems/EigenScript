#!/usr/bin/env bash
# #1382: control-flow AST nodes and every store use the statement's own line,
# and the synthetic program node does not put EOF at the front of every tape.
set -u

EIGS=${1:-./eigenscript}
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
TAPE=$(mktemp /tmp/eigs_line_stamps_XXXXXX.tape) || exit 1
trap 'rm -f "$TAPE"' EXIT

OUT=$(EIGS_JIT_OFF=1 EIGS_TRACE="$TAPE" "$EIGS" \
    "$TESTS_DIR/test_temporal_line_stamps.eigs" 2>&1)
RC=$?
LINES=$(sed -n 's/^L /L /p' "$TAPE")
EXPECTED='L 1
L 2
L 3
L 4
L 5
L 4
L 6
L 7
L 6
L 7
L 6
L 8
L 10
L 9
L 10
L 11
L 12
L 14
L 12
L 13
L 14
L 12
L 15
L 17
L 15
L 16
L 17
L 15
L 18
L 19
L 20
L 18
L 22'

if [ "$RC" -eq 0 ] && [ "$OUT" = null ] && [ "$LINES" = "$EXPECTED" ]; then
    echo "  PASS: control-flow and store stamps follow statement ownership"
    echo "All tests passed"
    exit 0
fi

echo "FAIL: temporal line stamps (rc=$RC, output='$OUT')"
echo "expected line trajectory:"
printf '%s\n' "$EXPECTED" | sed 's/^/  /'
echo "actual line trajectory:"
printf '%s\n' "$LINES" | sed 's/^/  /'
exit 1
