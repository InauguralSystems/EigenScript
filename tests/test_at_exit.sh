#!/bin/bash
# Runtime contract checks for `at_exit` (#1839).
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="${EIGS:-$TESTS_DIR/../src/eigenscript}"
PASS=0
FAIL=0

out=$($EIGS "$TESTS_DIR/at_exit_concurrent.eigs" 2>&1)
rc=$?
bad=0
for i in $(seq 0 23); do
    count=$(grep -cFx "AT_EXIT_WORKER $i" <<<"$out" || true)
    [ "$count" -eq 1 ] || bad=1
done
lines=$(grep -c '^AT_EXIT_WORKER ' <<<"$out" || true)
if [ "$rc" -eq 0 ] && [ "$bad" -eq 0 ] && [ "$lines" -eq 24 ]; then
    echo "  PASS: concurrent registrations each ran exactly once"
    PASS=$((PASS + 1))
else
    echo "  FAIL: concurrent registrations rc=$rc hook-lines=$lines"
    FAIL=$((FAIL + 1))
fi

out=$($EIGS "$TESTS_DIR/at_exit_continue.eigs" 2>&1)
rc=$?
first=$(grep -cFx 'AT_EXIT FIRST RAN' <<<"$out" || true)
third=$(grep -cFx 'AT_EXIT THIRD RAN' <<<"$out" || true)
middle_err=$(grep -c 'AT_EXIT MIDDLE ERROR' <<<"$out" || true)
third_err=$(grep -c 'AT_EXIT THIRD ERROR' <<<"$out" || true)
if [ "$rc" -eq 1 ] && [ "$first" -eq 1 ] && [ "$third" -eq 1 ] && \
   [ "$middle_err" -ge 1 ] && [ "$third_err" -ge 1 ]; then
    echo "  PASS: callback errors reported and remaining callbacks ran"
    PASS=$((PASS + 1))
else
    echo "  FAIL: callback continuation rc=$rc first=$first third=$third middle-errors=$middle_err third-errors=$third_err"
    printf '%s\n' "$out"
    FAIL=$((FAIL + 1))
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
