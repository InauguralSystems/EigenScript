#!/usr/bin/env bash
# [99x] state_at key order is deterministic (#1029). The prev table is
# bucketed by the interned name's ADDRESS, so a bucket-order walk printed
# state_at's keys in an ASLR-dependent order (seven orders in eight runs)
# and EIGS_REPLAY diverged from its own recording. The fix emits in NAME
# order. Oracle: N fresh processes (each under its own ASLR layout) print
# ONE distinct line, and that line is the sorted order. A planted revert to
# the bucket walk fails the first check on a normal kernel (ASLR on); if
# the box has ASLR off the second check (sorted order) still discriminates,
# because bucket order is not name order.
# No `timeout` here: macOS runners lack it (test-suite rule).
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$TESTS_DIR/../src/eigenscript"
PROG="$TESTS_DIR/state_at_order.eigs"
WANT='{"aa": 1, "bb": 2, "cc": 3, "dd": 4, "ee": 5, "ff": 6, "gg": 7, "hh": 8}'
outs=$(for k in 1 2 3 4 5 6 7 8; do "$EIGS" "$PROG" 2>&1; done)
distinct=$(printf '%s\n' "$outs" | sort -u | wc -l | tr -d ' ')
if [ "$distinct" = "1" ]; then
    echo "PASS: state_at order stable across 8 processes"
else
    echo "FAIL: state_at order varies across processes ($distinct distinct outputs)"
    printf '%s\n' "$outs" | sort | uniq -c | head -8
fi
first=$(printf '%s\n' "$outs" | head -1)
if [ "$first" = "$WANT" ]; then
    echo "PASS: state_at keys in name order"
else
    echo "FAIL: state_at keys not in name order: $first"
fi
# replay fidelity: a recording and its replay print the same dict
TAPE=$(mktemp "${TMPDIR:-/tmp}/state_at_order.XXXXXX")
rec=$("$EIGS" --trace "$TAPE" "$PROG" 2>&1)
rep=$(EIGS_REPLAY="$TAPE" "$EIGS" "$PROG" 2>&1)
rm -f "$TAPE"
if [ "$rec" = "$rep" ]; then
    echo "PASS: state_at replay matches its recording"
else
    echo "FAIL: state_at replay diverges: rec=$rec rep=$rep"
fi
