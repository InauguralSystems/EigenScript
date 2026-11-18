#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
EIGS=${EIGS:-$ROOT/src/eigenscript}
. "$ROOT/tests/lsan_classify.sh" || exit 1

# clean_exit WANT RC OUTPUT: the exit status is WANT and the output holds no
# sanitizer report of any kind. These rows tolerate no report, a leak-only one
# included, as the suite's other child scripts do (.claude/rules/test-suite.md:
# the sites that call lsan_classify and require "none"). The suite's ledger of
# tolerated leak reports is filled by rc_ok and rc_expect in the runner; a
# child script cannot add to it, so it does not tolerate what it cannot record.
clean_exit() {
    class=0
    lsan_classify "$3" || class=$?
    [ "$class" -eq 2 ] && [ "$2" -eq "$1" ]
}
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
    if clean_exit 0 "$rc" "$actual" && [ "$actual" = "$expected" ]; then
        echo "PASS: $name"
        passed=$((passed + 1))
    else
        echo "FAIL: $name (rc=$rc, expected '$expected'; the output follows, indented)"
        printf '%s\n' "$actual" | sed 's/^/    /'
        failed=$((failed + 1))
    fi
}

# Clean controls establish the string contract before the refusal plant.
check_value "secure_equals accepts two equal strings" 'secure_equals of ["abc", "abc"]' true
check_value "secure_equals accepts two unequal strings" 'secure_equals of ["abc", "abd"]' false

printf 'print of (secure_equals of [null, "abc"])\n' > "$T/non_string.eigs"
non_string_out=$("$EIGS" "$T/non_string.eigs" 2>&1)
non_string_rc=$?
if clean_exit 1 "$non_string_rc" "$non_string_out" && printf '%s\n' "$non_string_out" | grep -qF 'secure_equals: expected two strings'; then
    echo "PASS: secure_equals raises on a non-string with its contract message"
    passed=$((passed + 1))
else
    echo "FAIL: secure_equals non-string refusal (rc=$non_string_rc; the output follows, indented)"
    printf '%s\n' "$non_string_out" | sed 's/^/    /'
    failed=$((failed + 1))
fi

printf 'print of (secure_equals of [null, "abc"])\n' > "$T/non_string_lenient.eigs"
non_string_lenient_out=$(EIGS_STRICT=0 "$EIGS" "$T/non_string_lenient.eigs" 2>&1)
non_string_lenient_rc=$?
if clean_exit 0 "$non_string_lenient_rc" "$non_string_lenient_out" && [ "$non_string_lenient_out" = false ]; then
    echo "PASS: secure_equals answers false for a non-string under EIGS_STRICT=0"
    passed=$((passed + 1))
else
    echo "FAIL: secure_equals lenient non-string result (rc=$non_string_lenient_rc, expected 'false'; the output follows, indented)"
    printf '%s\n' "$non_string_lenient_out" | sed 's/^/    /'
    failed=$((failed + 1))
fi

echo "ISSUE_2252: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
