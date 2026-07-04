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

# --- W014: bare predicate in a multi-observe loop condition ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
x is 100.0
k is 0
loop while not converged:
    x is x * 0.5
    k is k + 1
print of x
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "W014 bare predicate, multi-observe loop" "$OUTPUT" "W014"
rm -f "$TMPFILE"

# --- W014 must NOT fire: single-observe loop body (unambiguous) ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
x is 100.0
loop while not converged:
    x is x * 0.5
print of x
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "W014 silent for single-observe loop" "$OUTPUT" "W014"
rm -f "$TMPFILE"

# --- W014 must NOT fire: named predicate form ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
x is 100.0
k is 0
loop while not (converged of x):
    x is x * 0.5
    k is k + 1
print of x
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "W014 silent for named predicate form" "$OUTPUT" "W014"
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

# --- Builtin shadowing via function DEFINITION (distinct from assignment) ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define len() as:
    return 0
print of (len of null)
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "fn-def builtin shadow" "$OUTPUT" "'len' is a builtin — function definition shadows it"
rm -f "$TMPFILE"

# --- Unreachable code inside a function, after an unconditional return ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define f(x) as:
    if x > 0:
        return 1
    return 2
    print of "dead"
print of (f of 5)
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "func unreachable after return" "$OUTPUT" "unreachable code after return"
rm -f "$TMPFILE"

# --- Feature-rich CLEAN file: walks every AST node kind through the lint
#     collectors (collect_refs / collect_assigns / check_builtin_shadow /
#     check_dup_keys / check_unused_params) without tripping a warning.
#     The small per-rule files above only exercise a few node types each.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define transform(items, factor) as:
    total is 0
    for it in items:
        total is total + (it * factor)
    return total

define classify(n) as:
    label is "?"
    if n > 10:
        label is "big"
    elif n > 5:
        label is "mid"
    else:
        label is "small"
    return label

define safe_div(a, b) as:
    result is 0
    try:
        result is a / b
    catch e:
        result is 0 - 1
    return result

config is {"scale": 2, "names": ["a", "b"], "nested": {"k": 1}}
doubler is (x) => x * 2
nums is [1, 2, 3, 4, 5]
squares is [v * v for v in nums]
total is transform of [nums, config.scale]
piped is total |> doubler
tag is classify of 7
dq is safe_div of [10, 2]
first_name is config.names[0]
deep is config.nested.k
m is "y"
matched is "none"
match m:
    case "x":
        matched is "ex"
    case "y":
        matched is "why"
    case _:
        matched is "other"
print of total
print of piped
print of tag
print of dq
print of squares[0]
print of first_name
print of deep
print of matched
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "feature-rich file lints clean" "$OUTPUT" "no issues found"
rm -f "$TMPFILE"

# --- Lint on a real stdlib file ---
OUTPUT=$($EIGS --lint "$TESTS_DIR/../examples/hello.eigs" 2>&1 || true)
check_contains "hello.eigs clean" "$OUTPUT" "no issues found"

# --- Diagnostic codes in human output ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
temp is 42
print of "hi"
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "human output carries [W001] code" "$OUTPUT" "warning\[W001\]"
rm -f "$TMPFILE"

# --- JSON mode: structured diagnostics on stdout ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
temp is 42
len is 7
print of "hi"
EIGS
# stdout only (2>/dev/null) must be valid JSON with both codes.
JSON=$($EIGS --lint --json "$TMPFILE" 2>/dev/null || true)
check_contains "json has W001" "$JSON" '"code":"W001"'
check_contains "json has W012" "$JSON" '"code":"W012"'
check_contains "json has severity" "$JSON" '"severity":"warning"'
if echo "$JSON" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
    check_contains "json parses (python)" "ok" "ok"
else
    check_contains "json parses (python)" "FAILED" "ok"
fi
# --json may also appear after the path.
JSON2=$($EIGS --lint "$TMPFILE" --json 2>/dev/null || true)
check_contains "json flag accepted after path" "$JSON2" '"code":"W001"'
rm -f "$TMPFILE"

# --- JSON mode: clean file is an empty array ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
echo 'print of "ok"' > "$TMPFILE"
JSON=$($EIGS --lint --json "$TMPFILE" 2>/dev/null || true)
check_contains "clean file json is []" "$JSON" '^\[\]$'
rm -f "$TMPFILE"

# --- JSON mode: parse error surfaces as E002 ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
printf 'if x > 0\n  print of x\n' > "$TMPFILE"
JSON=$($EIGS --lint --json "$TMPFILE" 2>/dev/null || true)
check_contains "parse error json has E002" "$JSON" '"code":"E002"'
check_contains "parse error json has error severity" "$JSON" '"severity":"error"'
rm -f "$TMPFILE"

# --- W015: assignment clobbers a module-level function ---
# Fires only when a function assigns (without `local`) over a module-level
# FUNCTION name — the unambiguous-bug core. Generic module VARIABLE reuse is
# benign under mutate-outward and deliberately NOT flagged (see the rule).
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
count is 0
define helper(n) as:
    return n
define bump(n) as:
    count is count + 1
    return count
define clobber(n) as:
    helper is 5
    return helper
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "W015 fires on function-name clobber" "$OUTPUT" "warning\[W015\]: 'helper'"
check_not_contains "W015 silent on generic module-variable reuse" "$OUTPUT" "'count'"
rm -f "$TMPFILE"

# Silent: `local`, a fresh function-local, param mutation, and (by convention)
# an `_`-prefixed module function treated as intentional private state.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define real_work(n) as:
    return n
define _private(n) as:
    return n
define caller(n) as:
    local real_work is n + 1
    _private is 9
    tmp is n * 2
    return real_work + tmp
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "W015 silent with local / fresh local / _-prefixed fn" "$OUTPUT" "W015"
rm -f "$TMPFILE"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
exit $FAIL
