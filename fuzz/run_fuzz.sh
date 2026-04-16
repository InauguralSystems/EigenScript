#!/bin/bash
# Run EigenScript fuzz test suite
# Feeds edge cases and adversarial inputs to the ASAN-instrumented binary.
# Any non-zero exit (except 1 for parse errors) indicates a crash.

cd "$(dirname "$0")/.."

FUZZ=./fuzz/fuzz_stdin
if [ ! -x "$FUZZ" ]; then
    echo "Build first: make fuzz"
    exit 1
fi

PASS=0
FAIL=0

fuzz_test() {
    local name="$1"
    local input="$2"
    local tmpfile
    tmpfile=$(mktemp /tmp/fuzz_XXXXXX.eigs)
    printf '%s\n' "$input" > "$tmpfile"
    timeout 5 "$FUZZ" < "$tmpfile" >/dev/null 2>&1
    local rc=$?
    rm -f "$tmpfile"
    if [ $rc -ne 0 ] && [ $rc -ne 1 ]; then
        echo "  FAIL: $name (exit $rc)"
        FAIL=$((FAIL + 1))
    else
        PASS=$((PASS + 1))
    fi
}

echo "=== EigenScript Fuzz Tests ==="
echo ""

echo "Edge cases:"
fuzz_test "division by zero" 'x is 1 / 0'
fuzz_test "index out of bounds" 'x is [1,2,3][999]'
fuzz_test "type error" 'x is "a" - 5'
fuzz_test "undefined variable" 'x is nonexistent'
fuzz_test "deep parens" "$(python3 -c "print('x is ' + '(' * 200 + '1' + ')' * 200)")"
fuzz_test "nested lists" "$(python3 -c "print('x is ' + '[' * 50 + '1' + ']' * 50)")"
fuzz_test "empty string" ''
fuzz_test "just braces" '{}'
fuzz_test "unmatched open" '['
fuzz_test "unmatched close" ']'
fuzz_test "bare keywords" 'define'
fuzz_test "bare if" 'if'
fuzz_test "bare match" 'match'
fuzz_test "bare try" 'try:'
fuzz_test "bad chars" 'x is @#$%^&'
fuzz_test "null bytes" 'x is "\x00\x01"'
fuzz_test "break outside loop" 'break'
fuzz_test "continue outside loop" 'continue'
fuzz_test "return at top level" 'return 42'
fuzz_test "huge number" 'x is 999999999999999999999999999999999.999'
fuzz_test "missing module" 'import nonexistent_module'
fuzz_test "pipe to non-fn" '1 |> 2 |> 3'
fuzz_test "for on non-list" 'for i in 99:\n    print of i'
fuzz_test "bad quotes" '""""""""""'
fuzz_test "unclosed f-string" 'f"{{{{{{{"'

echo ""
echo "Adversarial:"
fuzz_test "huge string" "$(python3 -c "print('x is \"' + 'A' * 60000 + '\"')")"
fuzz_test "many assignments" "$(python3 -c "print('\\n'.join(['x is ' + str(i) for i in range(1000)]))")"
fuzz_test "deep nesting" "$(python3 -c "print('if 1 == 1:\\n' + '    if 1 == 1:\\n' * 30 + '        x is 1')")"
fuzz_test "big dict" "$(python3 -c "print('x is {' + ', '.join(['\"k' + str(i) + '\": ' + str(i) for i in range(200)]) + '}')")"
fuzz_test "many match cases" "$(python3 -c "print('match 1:\\n' + ''.join(['    case ' + str(i) + ':\\n        x is ' + str(i) + '\\n' for i in range(100)]))")"

echo ""
echo "Corpus seeds:"
for f in fuzz/corpus/*.eigs; do
    name=$(basename "$f")
    fuzz_test "seed: $name" "$(cat "$f")"
done

echo ""
echo "============================================"
echo "  FUZZ: $PASS passed, $FAIL crashed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
