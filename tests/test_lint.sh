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

# --- #460: '# lint: loaded-by <file>' — a library fragment lints against
# its composer's transitive binding set; unlike allow-file E003, a genuine
# typo in the fragment still fires. Unresolvable context fails open.
FRAGDIR=$(mktemp -d /tmp/lint_frag_XXXXXX)
cat > "$FRAGDIR/entry.eigs" << 'EIGS'
define helper(x) as:
    return x + 1
load_file of "fragment.eigs"
EIGS
cat > "$FRAGDIR/fragment.eigs" << 'EIGS'
r is helper of 1
print of r
EIGS
OUTPUT=$($EIGS --lint "$FRAGDIR/fragment.eigs" 2>&1 || true)
check_contains "fragment standalone: E003 fires" "$OUTPUT" "E003.*undefined name 'helper'"
cat > "$FRAGDIR/fragment.eigs" << 'EIGS'
# lint: loaded-by entry.eigs
r is helper of 1
print of r
EIGS
OUTPUT=$($EIGS --lint "$FRAGDIR/fragment.eigs" 2>&1 || true)
check_not_contains "loaded-by kills the composition FP" "$OUTPUT" "E003"
cat > "$FRAGDIR/fragment.eigs" << 'EIGS'
# lint: loaded-by entry.eigs
r is helper of 1
q is no_such_name of 2
print of r
print of q
EIGS
OUTPUT=$($EIGS --lint "$FRAGDIR/fragment.eigs" 2>&1 || true)
check_contains "loaded-by keeps typo protection" "$OUTPUT" "E003.*undefined name 'no_such_name'"
check_not_contains "loaded-by silent on the composed name" "$OUTPUT" "undefined name 'helper'"
cat > "$FRAGDIR/fragment.eigs" << 'EIGS'
# lint: loaded-by missing.eigs
r is helper of 1
print of r
EIGS
OUTPUT=$($EIGS --lint "$FRAGDIR/fragment.eigs" 2>&1 || true)
check_not_contains "unresolvable loaded-by fails open" "$OUTPUT" "E003"
cat > "$FRAGDIR/sibling.eigs" << 'EIGS'
define assert_eq(args) as:
    return args[0] == args[1]
EIGS
cat > "$FRAGDIR/fragment.eigs" << 'EIGS'
# lint: loaded-by sibling.eigs
ok is assert_eq of [1, 1]
print of ok
EIGS
OUTPUT=$($EIGS --lint "$FRAGDIR/fragment.eigs" 2>&1 || true)
check_not_contains "concat-sibling context binds (no loader needed)" "$OUTPUT" "E003"
rm -rf "$FRAGDIR"

# --- #459: W012/W013 derive from register_builtins(), not a hand list ---
# `dispatch` and `chr` were registered builtins missing from the old
# hand-copied BUILTINS[] array, so shadowing them lint'd clean.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define dispatch(a, b, c) as:
    return 999
define report(v) as:
    return v
chr is 7
print of "hi"
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "W013 fires on define dispatch (#459)" "$OUTPUT" "W013.*'dispatch'"
check_contains "W013 fires on define report (observer special form)" "$OUTPUT" "W013.*'report'"
check_contains "W012 fires on a registry-only builtin (chr)" "$OUTPUT" "W012.*'chr'"
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
check_contains "parse error json carries a column (#407)" "$JSON" '"column":'
rm -f "$TMPFILE"

# --- #407: parse errors carry line:col in human output ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
printf 'value is 1 extra\n' > "$TMPFILE"   # two statements -> error at 'extra' (col 12)
OUTPUT=$($EIGS "$TMPFILE" 2>&1 || true)
check_contains "human parse error shows line:col" "$OUTPUT" "line 1:12:"
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

# --- W016: bare predicate OUTSIDE a loop condition (#396, #247/#262 family) ---
# Fires in if-conditions, assignment RHS, and return position; loop conditions
# are W014's territory (single-assign `loop while not converged` is the
# documented idiom and stays silent).
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
x is 1.0
x is x * 0.5
if stable:
    print of "settled"
ok is converged
print of ok
define check(n) as:
    return diverging
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "W016 fires on bare predicate in if-condition" "$OUTPUT" "warning\[W016\]: bare 'stable'"
check_contains "W016 fires on bare predicate in assignment" "$OUTPUT" "bare 'converged'"
check_contains "W016 fires on bare predicate in return" "$OUTPUT" "bare 'diverging'"
rm -f "$TMPFILE"

# Silent: loop-condition idiom (W014's territory), the named form, the
# explicit-subject #262 workaround `stable of (x + 0.0)`, and inline allow.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
x is 1.0
loop while not converged:
    x is x * 0.5
if stable of x:
    print of "settled"
if stable of (x + 0.0):
    print of "workaround"
y is converged of x
print of y
sup is stable  # lint: allow W016
print of sup
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "W016 silent: loop idiom / named / explicit subject / allow" "$OUTPUT" "W016"
rm -f "$TMPFILE"

# Multi-assign loop condition stays W014-only — no W016 double-fire.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
x is 1.0
i is 0
loop while not converged:
    x is x * 0.5
    i is i + 1
print of i
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "ambiguous loop still W014" "$OUTPUT" "W014"
check_not_contains "no W016 double-fire on loop condition" "$OUTPUT" "W016"
rm -f "$TMPFILE"

# --- #399: --lint-level threshold ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
printf 'temp is 42\nprint of "hi"\n' > "$TMPFILE"   # W001 unused variable
RC_DEFAULT=0; $EIGS --lint "$TMPFILE" >/dev/null 2>&1 || RC_DEFAULT=$?
RC_ERROR=0; $EIGS --lint --lint-level error "$TMPFILE" >/dev/null 2>&1 || RC_ERROR=$?
RC_WARN=0; $EIGS --lint --lint-level warning "$TMPFILE" >/dev/null 2>&1 || RC_WARN=$?
[ "$RC_DEFAULT" -eq 1 ] && { echo "  PASS: default level fails on warning (exit 1)"; PASS=$((PASS+1)); } || { echo "  FAIL: default level exit was $RC_DEFAULT"; FAIL=$((FAIL+1)); }
[ "$RC_ERROR" -eq 0 ] && { echo "  PASS: --lint-level error makes warnings advisory (exit 0)"; PASS=$((PASS+1)); } || { echo "  FAIL: --lint-level error exit was $RC_ERROR"; FAIL=$((FAIL+1)); }
[ "$RC_WARN" -eq 1 ] && { echo "  PASS: --lint-level warning fails on warning (exit 1)"; PASS=$((PASS+1)); } || { echo "  FAIL: --lint-level warning exit was $RC_WARN"; FAIL=$((FAIL+1)); }
TOTAL=$((TOTAL+3))
# warning is still REPORTED under --lint-level error (advisory, not hidden)
OUTPUT=$($EIGS --lint --lint-level error "$TMPFILE" 2>&1 || true)
check_contains "advisory warning still printed" "$OUTPUT" "W001"
rm -f "$TMPFILE"

# --- #399: inline suppression `# lint: allow` ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
printf 'temp is 42  # lint: allow W001\nprint of "hi"\n' > "$TMPFILE"
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "trailing '# lint: allow W001' suppresses it" "$OUTPUT" "W001"
RC_SUP=0; $EIGS --lint "$TMPFILE" >/dev/null 2>&1 || RC_SUP=$?
[ "$RC_SUP" -eq 0 ] && { echo "  PASS: suppressed file exits 0"; PASS=$((PASS+1)); } || { echo "  FAIL: suppressed file nonzero exit"; FAIL=$((FAIL+1)); }
TOTAL=$((TOTAL+1))
rm -f "$TMPFILE"

# comment on the line ABOVE also suppresses
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
printf '# lint: allow W001\ntemp is 42\nprint of "hi"\n' > "$TMPFILE"
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "'# lint: allow' on the line above suppresses" "$OUTPUT" "W001"
rm -f "$TMPFILE"

# a non-matching code does NOT over-suppress
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
printf 'temp is 42  # lint: allow W014\nprint of "hi"\n' > "$TMPFILE"
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "wrong code does not over-suppress W001" "$OUTPUT" "W001"
rm -f "$TMPFILE"

# --- E003 (#404): undefined name — no binding on any path ---
# Fires: a typo'd name in a cold branch — the classic dynamic-language bug
# that otherwise survives until that exact path executes at runtime.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
total is 0
flag is 1
if flag > 100:
    total is totl + 1
print of total
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "E003 fires on cold-branch typo" "$OUTPUT" "error\[E003\]: undefined name 'totl'"
# E003 is error-severity: it still fails under --lint-level error
RC_E=0; $EIGS --lint --lint-level error "$TMPFILE" >/dev/null 2>&1 || RC_E=$?
[ "$RC_E" -eq 1 ] && { echo "  PASS: E003 fails --lint-level error"; PASS=$((PASS+1)); } || { echo "  FAIL: E003 --lint-level error exit was $RC_E"; FAIL=$((FAIL+1)); }
TOTAL=$((TOTAL+1))
# JSON carries error severity
OUTPUT=$($EIGS --lint --json "$TMPFILE" 2>/dev/null || true)
check_contains "E003 JSON severity error" "$OUTPUT" '"code":"E003","severity":"error"'
rm -f "$TMPFILE"

# Fires in callee position too (typo'd function name).
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define compute(n) as:
    return n * 2
r is comptue of 21
print of r
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "E003 fires on typo'd callee" "$OUTPUT" "undefined name 'comptue'"
rm -f "$TMPFILE"

# Silent on the real scope rules: outward-`is`, `local` shadowing,
# sibling-branch first assignment, module-qualified names, and a builtin
# that postdates lint.c's old hand-copied list (bit_and) — the binding
# base comes from register_builtins() itself, so it cannot drift.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
flag is 1
count is 0
define bump(n) as:
    count is count + n
    return count
define shadowed(n) as:
    local count is n
    return count
if flag > 0:
    first is bump of 1
if flag > 1:
    second is first + (shadowed of 2)
    print of second
import util
u is util.helper
print of u
b is bit_and of [6, 3]
print of b
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "E003 silent on scope rules + registry builtins" "$OUTPUT" "E003"
rm -f "$TMPFILE"

# Silent on every binder form: for var, listcomp var, lambda params,
# catch var, list-pattern names.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
items is [1, 2, 3]
for it in items:
    print of it
doubled is [x * 2 for x in items]
print of doubled
f is (y) => y * 2
print of (f of 3)
try:
    throw of "boom"
catch err:
    print of err
[a, b] is [10, 20]
print of a + b
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "E003 silent on all binder forms" "$OUTPUT" "E003"
rm -f "$TMPFILE"

# A literal `load_file of "path"` is resolved with the runtime's own
# resolution chain and the loaded file's top-level binders count.
TMPLIB=$(mktemp /tmp/lint_lib_XXXXXX.eigs)
cat > "$TMPLIB" << 'EIGS'
define lib_helper(n) as:
    return n * 2
EIGS
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << EIGS
load_file of "$TMPLIB"
r is lib_helper of 21
print of r
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "E003 silent: name bound by literal load_file" "$OUTPUT" "E003"
# ...and the pass stays ON alongside literal loads: a name bound nowhere
# (not even in the loaded file) still fires.
cat > "$TMPFILE" << EIGS
load_file of "$TMPLIB"
r is lib_helper_missing of 21
print of r
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "E003 still fires alongside literal load_file" "$OUTPUT" "undefined name 'lib_helper_missing'"
rm -f "$TMPFILE" "$TMPLIB"

# Documented dynamic escape: `eval` anywhere disables the pass for the
# file (dynamic code can bind anything).
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
eval of "zz is 1"
print of zz
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "E003 disabled by eval (dynamic escape)" "$OUTPUT" "E003"
rm -f "$TMPFILE"

# Computed load_file path likewise disables the pass.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
p is "unknowable.eigs"
load_file of p
print of mystery_name
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "E003 disabled by computed load_file" "$OUTPUT" "E003"
rm -f "$TMPFILE"

# `# lint: allow E003` suppresses per-site (host-injected names).
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
printf 'print of injected_by_host  # lint: allow E003\n' > "$TMPFILE"
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "E003 suppressed by inline allow" "$OUTPUT" "E003"
rm -f "$TMPFILE"

# `# lint: allow-file E003` suppresses file-wide (module fragments) —
# and does NOT over-suppress other codes.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
# lint: allow-file E003 -- fragment: the loader binds shared state
define widget(x) as:
    return _theme_color of x
r is widget of 1
print of r
unused_tmp is 42
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "allow-file E003 suppresses file-wide" "$OUTPUT" "E003"
check_contains "allow-file does not over-suppress other codes" "$OUTPUT" "W001"
rm -f "$TMPFILE"

# --- E003 increment two (#404): scope-precise binding sets ---
# Every rule below is pinned against the interpreter: each firing fixture
# is a program the runtime rejects with "undefined variable", each silent
# fixture is a program the runtime runs clean.

# Fires: a function-local (plain `is` on a fresh name, and `local`) is
# invisible to module code and sibling functions.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define g() as:
    fn_only is 42
    local fn_local is 7
    return fn_only + fn_local
define h() as:
    return fn_only
r is g of null
print of fn_local
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "E003 fires on sibling read of fn-local" "$OUTPUT" "undefined name 'fn_only'"
check_contains "E003 fires on module read of local" "$OUTPUT" "undefined name 'fn_local'"
rm -f "$TMPFILE"

# Fires: a nested define binds in the enclosing function only.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define outer() as:
    define inner() as:
        return 1
    return inner of null
r is outer of null
print of (inner of null)
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "E003 fires on module call of nested define" "$OUTPUT" "undefined name 'inner'"
rm -f "$TMPFILE"

# Fires: a module-level `for` loop-scopes its variable — the VM drops it
# at loop exit, so a post-loop read is a runtime error.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
acc is 0
for item in [1, 2, 3]:
    acc is acc + item
print of item
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "E003 fires on post-loop read of module for-var" "$OUTPUT" "undefined name 'item'"
rm -f "$TMPFILE"

# Near-miss suggestion: edit-distance-1 against the visible binding set.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
total is 100
print of totl
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "E003 suggests the near-miss binding" "$OUTPUT" "did you mean 'total'?"
rm -f "$TMPFILE"

# Silent: the scope rules the runtime actually has — closures read
# enclosing function locals; a function body reads a module name bound
# after the definition; a FUNCTION-level for-var survives its loop;
# a listcomp var leaks to the containing scope; a closure defined in a
# module loop body reads the loop var.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define outer() as:
    local z is 7
    define inner() as:
        return z
    return inner of null
define late_reader() as:
    return bound_later
define fn_for() as:
    for j in [1, 2]:
        x is j
    return j
bound_later is 5
squares is [v * v for v in [1, 2]]
last_v is v
fns is []
for k in [1, 2]:
    define mk() as:
        return k
    append of [fns, mk]
first is fns[0]
total_sum is (outer of null) + (late_reader of null) + (fn_for of null) + last_v + (first of null) + squares[0]
print of total_sum
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "E003 silent on scope-precise legal reads" "$OUTPUT" "E003"
rm -f "$TMPFILE"

# --- #469 (W018): e.kind compared against an out-of-set error kind ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
try:
    x is [1][9]
catch e:
    if e.kind == "index_rage":
        print of "oops"
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "W018 fires on a typo'd error kind (index_rage)" "$OUTPUT" "W018"
check_contains "W018 suggests the near-miss kind" "$OUTPUT" "index_range"
rm -f "$TMPFILE"

TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
try:
    x is 1
catch e:
    if e.kind == "IO":
        print of "io"
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "W018 fires on a case-variant kind (IO)" "$OUTPUT" "W018"
rm -f "$TMPFILE"

TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
try:
    x is [1][9]
catch e:
    if e.kind == "index_range":
        print of "ok"
    if e.kind != "deadlock":
        print of "not dl"
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "W018 silent on valid kinds (incl. post-#509 deadlock)" "$OUTPUT" "W018"
rm -f "$TMPFILE"

TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
try:
    throw {kind: "payment_declined", message: "no"}
catch e:
    if e.kind == "payment_declined":
        print of "custom"
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "W018 silent on a genuine custom (far-off) kind" "$OUTPUT" "W018"
rm -f "$TMPFILE"

TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
d is {kind: "index_rage"}
if d.kind == "index_rage":
    print of "not an error dict"
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "W018 silent on .kind off a non-catch (user dict) var" "$OUTPUT" "W018"
rm -f "$TMPFILE"

# --- #455: per-file lint allow-list in eigs.json ---
# A project can suppress a code for a whole file via eigs.json, without inline
# comments (generated/vendored code). Resolution walks to the project root
# (dir with eigs.json) regardless of the cwd the linter runs from.
LINTPKG=$(mktemp -d /tmp/lint_pkg_XXXXXX)
mkdir -p "$LINTPKG/lib"
# W017: 'f of [<expr>]' — one bare-list arg.
printf 'define f(x) as:\n    return x\nprint of (f of [1])\n' > "$LINTPKG/lib/gen.eigs"
cp "$LINTPKG/lib/gen.eigs" "$LINTPKG/lib/other.eigs"

printf '{ "lint": { "allow": { "lib/gen.eigs": ["W017"] } } }\n' > "$LINTPKG/eigs.json"
OUT_ALLOW=$($EIGS --lint "$LINTPKG/lib/gen.eigs" 2>&1 || true)
check_not_contains "#455 eigs.json allow suppresses listed code for the file" "$OUT_ALLOW" "W017"

OUT_OTHER=$($EIGS --lint "$LINTPKG/lib/other.eigs" 2>&1 || true)
check_contains "#455 a file not in the allow-list still fires" "$OUT_OTHER" "W017"

printf '{ "lint": { "allow": { "lib/gen.eigs": ["W003"] } } }\n' > "$LINTPKG/eigs.json"
OUT_WRONGCODE=$($EIGS --lint "$LINTPKG/lib/gen.eigs" 2>&1 || true)
check_contains "#455 allowing a different code leaves W017 firing" "$OUT_WRONGCODE" "W017"

printf '{ "lint": { "allow": { "lib/gen.eigs": ["all"] } } }\n' > "$LINTPKG/eigs.json"
OUT_ALL=$($EIGS --lint "$LINTPKG/lib/gen.eigs" 2>&1 || true)
check_not_contains "#455 'all' suppresses every code for the file" "$OUT_ALL" "W017"

# Root discovery is cwd-independent.
printf '{ "lint": { "allow": { "lib/gen.eigs": ["W017"] } } }\n' > "$LINTPKG/eigs.json"
OUT_CWD=$( (cd / && "$EIGS" --lint "$LINTPKG/lib/gen.eigs" 2>&1) || true)
check_not_contains "#455 allow-list resolves from project root, not cwd" "$OUT_CWD" "W017"
rm -rf "$LINTPKG"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
exit $FAIL
