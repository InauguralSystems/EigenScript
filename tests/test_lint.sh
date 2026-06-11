#!/bin/bash
# Test the EigenScript linter (--lint)
set -e
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$TESTS_DIR/../src/eigenscript"

PASS=0
FAIL=0
TOTAL=0

check_contains() {
    TOTAL=$((TOTAL + 1))
    local test_name="$1"
    local output="$2"
    local expected_pattern="$3"
    if echo "$output" | grep -q "$expected_pattern"; then
        echo "  PASS: $test_name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $test_name (pattern '$expected_pattern' not found)"
        echo "    output: $(echo "$output" | head -5)"
        FAIL=$((FAIL + 1))
    fi
}

check_not_contains() {
    TOTAL=$((TOTAL + 1))
    local test_name="$1"
    local output="$2"
    local pattern="$3"
    if echo "$output" | grep -q "$pattern"; then
        echo "  FAIL: $test_name (pattern '$pattern' should not appear)"
        echo "    output: $(echo "$output" | head -5)"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $test_name"
        PASS=$((PASS + 1))
    fi
}

echo "=== Linter Tests ==="

# --- Unused variable ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
temp is 42
print of "hello"
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "unused variable" "$OUTPUT" "unused variable 'temp'"
rm -f "$TMPFILE"

# --- Clean file (no warnings) ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
print of "Hello, World!"
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "clean file" "$OUTPUT" "no issues found"
rm -f "$TMPFILE"

# --- Unreachable code ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define foo() as:
    return 1
    x is 2
    print of x
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "unreachable code" "$OUTPUT" "unreachable code after return"
rm -f "$TMPFILE"

# --- Builtin shadowing ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
print is 42
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "builtin shadow" "$OUTPUT" "'print' is a builtin"
rm -f "$TMPFILE"

# --- Duplicate dict keys ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
d is {"a": 1, "a": 2}
print of d
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "duplicate dict key" "$OUTPUT" "duplicate dict key 'a'"
rm -f "$TMPFILE"

# --- Multiple warnings on one file ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
len is 42
temp is 99
print of "hello"
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "builtin shadow (len)" "$OUTPUT" "'len' is a builtin"
check_contains "unused variable (temp)" "$OUTPUT" "unused variable 'temp'"
rm -f "$TMPFILE"

# --- Unused function parameter ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define foo(x, y) as:
    return x
result is foo of [1, 2]
print of result
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "unused parameter" "$OUTPUT" "unused parameter 'y'"
rm -f "$TMPFILE"

# --- _prefixed param should NOT warn ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define foo(x, _unused) as:
    return x
result is foo of [1, 2]
print of result
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "_prefixed param no warning" "$OUTPUT" "unused parameter '_unused'"
rm -f "$TMPFILE"

# --- Lint on a real stdlib file ---
OUTPUT=$($EIGS --lint "$TESTS_DIR/../examples/hello.eigs" 2>&1 || true)
check_contains "hello.eigs clean" "$OUTPUT" "no issues found"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
exit $FAIL
