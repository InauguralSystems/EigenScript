#!/bin/bash
# Test the EigenScript test runner (--test) and the exe_path builtin.
set -e
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$TESTS_DIR/../src/eigenscript"

PASS=0
FAIL=0
TOTAL=0

check_contains() {
    TOTAL=$((TOTAL + 1))
    local name="$1" output="$2" pat="$3"
    if echo "$output" | grep -q "$pat"; then
        echo "  PASS: $name"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $name (pattern '$pat' not found)"
        echo "    output: $(echo "$output" | head -5)"; FAIL=$((FAIL + 1))
    fi
}
check_eq() {
    TOTAL=$((TOTAL + 1))
    local name="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        echo "  PASS: $name"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $name (got '$got', want '$want')"; FAIL=$((FAIL + 1))
    fi
}

echo "=== Test Runner Tests ==="

# exe_path returns the running interpreter's absolute path.
TMP=$(mktemp /tmp/trun_XXXXXX.eigs)
echo 'print of (exe_path of null)' > "$TMP"
OUT=$($EIGS "$TMP" 2>/dev/null || true)
check_contains "exe_path is absolute" "$OUT" "^/"
check_contains "exe_path names the binary" "$OUT" "eigenscript"
rm -f "$TMP"

# Build a fixture directory with one passing and one failing test file.
WORK=$(mktemp -d /tmp/trun_dir_XXXXXX)
cat > "$WORK/test_pass.eigs" << 'EIGS'
load_file of "lib/test.eigs"
assert_eq of [2 + 2, 4, "arith"]
assert_true of [1 < 2, "lt"]
test_summary of null
EIGS
cat > "$WORK/test_fail.eigs" << 'EIGS'
load_file of "lib/test.eigs"
assert_eq of [1 + 1, 3, "wrong"]
test_summary of null
EIGS
# Not a test_*.eigs file — must be ignored by discovery.
echo 'print of "ignore me"' > "$WORK/helper.eigs"

# --- Human mode: both files discovered, one pass one fail, exit 1 ---
OUT=$($EIGS --test "$WORK" 2>/dev/null || true)
RC=$($EIGS --test "$WORK" >/dev/null 2>&1; echo $?)
check_contains "human PASS line" "$OUT" "PASS  $WORK/test_pass.eigs"
check_contains "human FAIL line" "$OUT" "FAIL  $WORK/test_fail.eigs"
check_contains "human summary" "$OUT" "Files: 2 | Passed: 1 | Failed: 1"
check_contains "human shows failing assert" "$OUT" "expected 3, got 2"
check_contains "non-test file ignored" "$( [ -z "$(echo "$OUT" | grep helper.eigs)" ] && echo OK )" "OK"
check_eq "exit nonzero when a file fails" "$RC" "1"

# --- JSON mode: valid JSON, correct aggregate, exit 1 ---
JSON=$($EIGS --test "$WORK" --json 2>/dev/null || true)
if echo "$JSON" | python3 -m json.tool >/dev/null 2>&1; then
    check_contains "json parses" "ok" "ok"
else
    check_contains "json parses" "FAILED" "ok"
fi
check_contains "json files=2" "$JSON" '"files":2'
check_contains "json passed=1" "$JSON" '"passed":1'
check_contains "json failed=1" "$JSON" '"failed":1'
check_contains "json per-file status" "$JSON" '"status":"fail"'

# --- All-pass directory: exit 0 ---
WORK2=$(mktemp -d /tmp/trun_ok_XXXXXX)
cp "$WORK/test_pass.eigs" "$WORK2/"
RC=$($EIGS --test "$WORK2" >/dev/null 2>&1; echo $?)
check_eq "exit 0 when all pass" "$RC" "0"
JSON=$($EIGS --test "$WORK2" --json 2>/dev/null || true)
check_contains "all-pass json failed=0" "$JSON" '"failed":0'

# --- Single-file invocation ---
OUT=$($EIGS --test "$WORK/test_pass.eigs" 2>/dev/null || true)
check_contains "single-file runs" "$OUT" "Files: 1 | Passed: 1 | Failed: 0"

# --- No test files: friendly message, exit 0 ---
WORK3=$(mktemp -d /tmp/trun_empty_XXXXXX)
OUT=$($EIGS --test "$WORK3" 2>/dev/null || true)
RC=$($EIGS --test "$WORK3" >/dev/null 2>&1; echo $?)
check_contains "no-tests message" "$OUT" "No test files found"
check_eq "no-tests exit 0" "$RC" "0"

rm -rf "$WORK" "$WORK2" "$WORK3"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
exit $FAIL
