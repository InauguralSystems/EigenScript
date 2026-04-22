#!/bin/bash
# Test the EigenScript formatter (--fmt)
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$TESTS_DIR/../src/eigenscript"

PASS=0
FAIL=0
TOTAL=0

check() {
    TOTAL=$((TOTAL + 1))
    local test_name="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $test_name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $test_name"
        echo "    expected: |$(echo "$expected" | head -3)|"
        echo "    actual:   |$(echo "$actual" | head -3)|"
        FAIL=$((FAIL + 1))
    fi
}

fmt_str() {
    local input="$1"
    local tmpf
    tmpf=$(mktemp /tmp/fmt_test_XXXXXX.eigs)
    printf '%s' "$input" > "$tmpf"
    $EIGS --fmt "$tmpf" 2>/dev/null
    rm -f "$tmpf"
}

echo "=== Formatter Tests ==="

# --- Indentation normalization ---
ACTUAL=$(fmt_str "$(printf 'define foo(x) as:\n  return x\n')")
EXPECTED=$(printf 'define foo(x) as:\n    return x\n')
check "indent normalization (2->4)" "$ACTUAL" "$EXPECTED"

# --- Trailing whitespace removal ---
ACTUAL=$(fmt_str "$(printf 'x is 42   \ny is 10  \n')")
EXPECTED=$(printf 'x is 42\ny is 10\n')
check "trailing whitespace removal" "$ACTUAL" "$EXPECTED"

# --- Collapse multiple blank lines ---
ACTUAL=$(fmt_str "$(printf 'x is 1\n\n\n\ny is 2\n')")
EXPECTED=$(printf 'x is 1\n\ny is 2\n')
check "collapse multiple blank lines" "$ACTUAL" "$EXPECTED"

# --- Space after comma ---
ACTUAL=$(fmt_str "$(printf '[1,2,3]\n')")
EXPECTED=$(printf '[1, 2, 3]\n')
check "space after comma" "$ACTUAL" "$EXPECTED"

# --- No space before comma ---
ACTUAL=$(fmt_str "$(printf '[1 , 2 , 3]\n')")
EXPECTED=$(printf '[1, 2, 3]\n')
check "no space before comma" "$ACTUAL" "$EXPECTED"

# --- No space inside brackets ---
ACTUAL=$(fmt_str "$(printf '[ 1, 2, 3 ]\n')")
EXPECTED=$(printf '[1, 2, 3]\n')
check "no space inside brackets" "$ACTUAL" "$EXPECTED"

# --- Comment spacing ---
ACTUAL=$(fmt_str "$(printf '#comment here\n')")
EXPECTED=$(printf '# comment here\n')
check "space after # in comment" "$ACTUAL" "$EXPECTED"

# --- Operator spacing ---
ACTUAL=$(fmt_str "$(printf 'x is 1+2\n')")
EXPECTED=$(printf 'x is 1 + 2\n')
check "space around +" "$ACTUAL" "$EXPECTED"

# --- Comparison operator spacing ---
ACTUAL=$(fmt_str "$(printf 'if x==5:\n')")
EXPECTED=$(printf 'if x == 5:\n')
check "space around ==" "$ACTUAL" "$EXPECTED"

# --- Final newline ---
ACTUAL=$(fmt_str "$(printf 'x is 42')")
EXPECTED=$(printf 'x is 42\n')
check "final newline" "$ACTUAL" "$EXPECTED"

# --- String content preserved ---
ACTUAL=$(fmt_str "$(printf 'x is "hello,world"\n')")
EXPECTED=$(printf 'x is "hello,world"\n')
check "string content not modified" "$ACTUAL" "$EXPECTED"

# --- Idempotency on clean file ---
ORIGINAL=$($EIGS --fmt examples/hello.eigs 2>/dev/null)
TMPF=$(mktemp /tmp/fmt_test_XXXXXX.eigs)
printf '%s' "$ORIGINAL" > "$TMPF"
DOUBLE=$($EIGS --fmt "$TMPF" 2>/dev/null)
rm -f "$TMPF"
check "idempotent on hello.eigs" "$DOUBLE" "$ORIGINAL"

# --- Blank line between top-level defines ---
ACTUAL=$(fmt_str "$(printf 'define foo() as:\n    return 1\ndefine bar() as:\n    return 2\n')")
EXPECTED=$(printf 'define foo() as:\n    return 1\n\ndefine bar() as:\n    return 2\n')
check "blank line between defines" "$ACTUAL" "$EXPECTED"

# --- Write mode ---
TMPFILE=$(mktemp /tmp/fmt_test_XXXXXX.eigs)
printf 'x is 1+2\n' > "$TMPFILE"
$EIGS --fmt --write "$TMPFILE" 2>/dev/null
ACTUAL=$(cat "$TMPFILE")
EXPECTED=$(printf 'x is 1 + 2\n')
check "--write mode" "$ACTUAL" "$EXPECTED"
rm -f "$TMPFILE"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
[ "$FAIL" -eq 0 ]
