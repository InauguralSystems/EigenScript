#!/usr/bin/env bash
set -u

EIGS=${EIGS:-$(cd "$(dirname "$0")/.." && pwd)/src/eigenscript}
T=$(mktemp -d -t eigs-2252.XXXXXX) || exit 2
trap 'rm -rf "$T"' EXIT
passed=0
failed=0

check_value() {
    name=$1
    expression=$2
    expected=$3
    printf 'print of (%s)\n' "$expression" > "$T/case.eigs"
    actual=$("$EIGS" "$T/case.eigs" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$actual" = "$expected" ]; then
        echo "PASS: $name"
        passed=$((passed + 1))
    else
        echo "FAIL: $name (rc=$rc, got '$actual', expected '$expected')"
        failed=$((failed + 1))
    fi
}

# Clean controls establish the string contract before the refusal plant.
check_value "secure_equals accepts two equal strings" 'secure_equals of ["abc", "abc"]' true
check_value "secure_equals accepts two unequal strings" 'secure_equals of ["abc", "abd"]' false

printf 'print of (secure_equals of [null, "abc"])\n' > "$T/non_string.eigs"
non_string_out=$("$EIGS" "$T/non_string.eigs" 2>&1)
non_string_rc=$?
if [ "$non_string_rc" -ne 0 ] && printf '%s\n' "$non_string_out" | grep -qF 'secure_equals: expected two strings'; then
    echo "PASS: secure_equals raises on a non-string with its contract message"
    passed=$((passed + 1))
else
    echo "FAIL: secure_equals non-string refusal (rc=$non_string_rc)"
    printf '%s\n' "$non_string_out"
    failed=$((failed + 1))
fi

echo "ISSUE_2252: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
