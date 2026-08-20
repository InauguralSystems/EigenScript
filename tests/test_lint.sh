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

# Exit status is a lint result in its own right — a CI gate reads it and
# nothing else (#927), so assert it directly rather than inferring it from
# the message.
check_status() {
    TOTAL=$((TOTAL + 1))
    local test_name="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $test_name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $test_name (exit $actual, expected $expected)"
        FAIL=$((FAIL + 1))
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

# --- #783: W010 (duplicate dict key) recurses into unobserved blocks ---
# check_dup_keys used to break on AST_UNOBSERVED, so a dict literal inside
# an unobserved: block was never reached and never warned on.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
unobserved:
    w010_d is {"a": 1, "a": 2}
print of w010_d
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#783 W010 fires inside an unobserved block" "$OUTPUT" "W010.*'a'"
rm -f "$TMPFILE"

# --- #783: W010 (duplicate dict key) recurses into match arms ---
# check_dup_keys used to break on AST_MATCH, so a dict literal inside a
# match arm was never reached and never warned on.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
match 1:
    case 1:
        w010_d is {"a": 1, "a": 2}
    case _:
        x is 0
print of 1
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#783 W010 fires inside a match arm" "$OUTPUT" "W010.*'a'"
rm -f "$TMPFILE"

# --- #783: W010 (duplicate dict key) recurses into the match scrutinee ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
match {"a": 1, "a": 2}:
    case _:
        print of "fallback"
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#783 W010 fires in the match scrutinee" "$OUTPUT" "W010.*'a'"
rm -f "$TMPFILE"

# --- #783: W010 (duplicate dict key) recurses into match patterns ---
# Patterns are full expressions (parser.c parses them with parse_expression),
# so a dict literal used as a case pattern must be walked too. The wildcard
# case _ stores a NULL pattern; check_dup_keys' !node guard covers it.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
x is 1
match x:
    case {"a": 1, "a": 2}:
        print of "dict"
    case _:
        print of "other"
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#783 W010 fires in a match pattern" "$OUTPUT" "W010.*'a'"
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

# --- #781: W002 recurses into unobserved blocks and match arms ---
# check_unused_params used to break on AST_UNOBSERVED/AST_MATCH, so a define
# inside those scopes never had its params checked.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define w002_ctrl(unusedparam) as:
    return 1
w002_ctrl of 9
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#781 W002 still fires at top level" "$OUTPUT" "W002.*'unusedparam' in function 'w002_ctrl'"
rm -f "$TMPFILE"

TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
unobserved:
    define w002_u(unusedparam) as:
        return 1
w002_u of 9
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#781 W002 fires inside an unobserved block" "$OUTPUT" "W002.*'unusedparam' in function 'w002_u'"
rm -f "$TMPFILE"

TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
match 1:
    case 1:
        define w002_m(unusedparam) as:
            return 1
    case _:
        print of "none"
w002_m of 9
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#781 W002 fires inside a match arm" "$OUTPUT" "W002.*'unusedparam' in function 'w002_m'"
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

# --- #782: W003 (unreachable code) recurses into unobserved blocks and match arms ---
# check_func_unreachable used to break on AST_UNOBSERVED/AST_MATCH, so a
# function defined there never had its body scanned for dead code.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
unobserved:
    define w003_u() as:
        return 1
        dead_stmt is 2
w003_u of null
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#782 W003 fires inside an unobserved block" "$OUTPUT" "W003.*unreachable code after return"
rm -f "$TMPFILE"

TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
match 1:
    case 1:
        define w003_m() as:
            return 1
            dead_stmt is 2
    case _:
        x is 0
w003_m of null
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#782 W003 fires inside a match arm" "$OUTPUT" "W003.*unreachable code after return"
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

define categorize(n) as:
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
tag is categorize of 7
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

# --- W023: inverted sibling-branch outer-mutation fence (#870) ---
# A try-region local dominates the sibling write at runtime, so the warning
# must stay silent even though the branch pair itself matches the trigger.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
t is 5
define f(flag) as:
    try:
        local t is 9
    catch e:
        print of "nope"
    if flag == 1:
        local t is 1
    else:
        t is 2
    return t
print of ("return value is " + (str of (f of 0)))
print of ("module t is now " + (str of t))
EIGS
RUN=$($EIGS "$TMPFILE" 2>&1 || true)
check_contains "W023 try-region local returns 2" "$RUN" "2"
check_contains "W023 try-region local leaves module t at 5" "$RUN" "module t is now 5"
OUTPUT=$($EIGS --lint --lint-level error "$TMPFILE" 2>&1) && LINT_STATUS=0 || LINT_STATUS=$?
check_status "W023 silent: try-region local lint exits 0" "$LINT_STATUS" "0"
check_not_contains "W023 silent: try-region local" "$OUTPUT" "W023"
rm -f "$TMPFILE"

# A preceding import emits OP_SET_NAME_LOCAL, so the later bare assignment
# resolves to that function environment binding rather than module math.  The
# runtime assertions make this a real ownership check, not a lint-output-only
# characterization: the import owns the write and the module value stays 5.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
math is 5
define f(flag) as:
    import math
    if flag == 1:
        local math is 1
    else:
        math is 2
    return math
print of ("W023 import return is " + (str of (f of 0)))
print of ("W023 import module math is " + (str of math))
EIGS
RUN=$($EIGS "$TMPFILE" 2>&1 || true)
check_contains "W023 import runtime writes the function binding" "$RUN" "W023 import return is 2"
check_contains "W023 import runtime leaves module binding unchanged" "$RUN" "W023 import module math is 5"
OUTPUT=$($EIGS --lint --lint-level error "$TMPFILE" 2>&1) && LINT_STATUS=0 || LINT_STATUS=$?
check_status "W023 silent when preceding import owns bare write" "$LINT_STATUS" "0"
check_not_contains "W023 silent for current-scope import binder" "$OUTPUT" "W023"
rm -f "$TMPFILE"

# A nested define binds the name in the current function and likewise
# dominates the sibling write; the runtime must leave the module binding alone.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
t is 5
define f(flag) as:
    define t() as:
        return 1
    if flag == 1:
        local t is 1
    else:
        t is 2
    return t
print of (str of (f of 0))
print of ("module t is now " + (str of t))
EIGS
RUN=$($EIGS "$TMPFILE" 2>&1 || true)
check_contains "W023 nested define returns 2" "$RUN" "2"
check_contains "W023 nested define leaves module t at 5" "$RUN" "module t is now 5"
OUTPUT=$($EIGS --lint --lint-level error "$TMPFILE" 2>&1) && LINT_STATUS=0 || LINT_STATUS=$?
check_status "W023 silent: nested define lint exits 0" "$LINT_STATUS" "0"
check_not_contains "W023 silent: nested define" "$OUTPUT" "W023"
rm -f "$TMPFILE"

# No dominating binder exists here: the bare sibling write really mutates the
# module binding and must be diagnosed with the new warning code.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
t is 5
define f(flag) as:
    if flag == 1:
        local t is 1
    else:
        t is 2
    return t
print of ("return value is " + (str of (f of 0)))
print of ("module t is now " + (str of t))
EIGS
RUN=$($EIGS "$TMPFILE" 2>&1 || true)
check_contains "W023 planted mutation returns 2" "$RUN" "^return value is 2$"
check_contains "W023 planted mutation changes module t" "$RUN" "module t is now 2"
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "W023 fires on sibling-branch outer mutation" "$OUTPUT" "warning\[W023\]: 't'"
rm -f "$TMPFILE"

# Binding identity is exact: a local `x` in one arm does not justify a bare
# `t` in its sibling.  The runtime still mutates module t, but W023 must stay
# silent because the proof names differ.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
t is 5
define f(flag) as:
    if flag == 1:
        local x is 1
    else:
        t is 2
    return t
print of ("different-name return is " + (str of (f of 0)))
print of ("different-name module t is " + (str of t))
EIGS
RUN=$($EIGS "$TMPFILE" 2>&1 || true)
check_contains "W023 different-name runtime mutates t" "$RUN" "different-name module t is 2"
OUTPUT=$($EIGS --lint --lint-level error "$TMPFILE" 2>&1) && LINT_STATUS=0 || LINT_STATUS=$?
check_status "W023 silent for different-name siblings" "$LINT_STATUS" "0"
check_not_contains "W023 exact proof-name identity" "$OUTPUT" "W023"
rm -f "$TMPFILE"

# A complete proof nested under another control-flow node must still fire.
# This is deliberately outward at runtime (5 -> 2), unlike the dominating
# local nested case above; a walker that skips all nested live diagnostics
# must fail the warning assertion here.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
t is 5
define f(flag) as:
    if flag == 0:
        if flag == 1:
            local t is 1
        else:
            t is 2
    else:
        print of "skip"
    return t
print of ("nested live return is " + (str of (f of 0)))
print of ("nested live module t is " + (str of t))
EIGS
RUN=$($EIGS "$TMPFILE" 2>&1 || true)
check_contains "W023 nested live runtime mutates t" "$RUN" "nested live module t is 2"
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1) && LINT_STATUS=0 || LINT_STATUS=$?
check_status "W023 nested live lint returns a warning result" "$LINT_STATUS" "1"
check_contains "W023 fires for nested live mutation" "$OUTPUT" "warning\[W023\]: 't'"
rm -f "$TMPFILE"

# Allocation failure is injected at the real branch/count growth boundary.
# The hook arms after W023's 1,024-byte branch vector succeeds and fails the
# immediately following 512-byte count vector.  RED must be the linter
# survival/suppression assertion; a current abort is the defect, never the
# expected pass condition.  Linux release runners only: LD_PRELOAD is not a
# portable macOS mechanism, and sanitizer allocators own their interposition.
ALLOC_CC=$(command -v "${ALLOC_COMPILER:-cc}" 2>/dev/null || true)
if [ "$(uname -s)" = Linux ] && [ -n "$ALLOC_CC" ] \
    && ! ldd "$EIGS" 2>/dev/null | grep -q 'libasan\|libclang_rt.asan'; then
    ALLOC_SRC=$(mktemp /tmp/w023_alloc_fail_XXXXXX.c)
    ALLOC_SO=$(mktemp /tmp/w023_alloc_fail_XXXXXX.so)
    cat > "$ALLOC_SRC" << 'C'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>
#include <stdlib.h>
#include <unistd.h>

static void *(*real_realloc_fn)(void *, size_t);
static __thread int resolving;
static int armed;
static int failed;

static void resolve_realloc(void) {
    if (real_realloc_fn) return;
    resolving = 1;
    real_realloc_fn = (void *(*)(void *, size_t))dlsym(RTLD_NEXT, "realloc");
    resolving = 0;
}

void *realloc(void *ptr, size_t size) {
    void *result;
    resolve_realloc();
    if (!real_realloc_fn) _exit(125);
    if (!resolving && size == 1024) {
        result = real_realloc_fn(ptr, size);
        if (result) armed = 1;
        return result;
    }
    if (!resolving && armed) {
        armed = 0;
        if (!failed && size == 512) {
            failed = 1;
            /* glibc marks write() warn_unused_result, and this helper is
               compiled -O2 -Wall -Wextra -Werror, so ignoring it is a hard
               error. Capture and discard explicitly. */
            ssize_t wr = write(STDERR_FILENO, "W023_ALLOC_HOOK_FAILED\n", 23);
            (void)wr;
            return NULL;
        }
    }
    return real_realloc_fn(ptr, size);
}
C
    if "$ALLOC_CC" -shared -fPIC -O2 -Wall -Wextra -Werror -Werror=switch -o "$ALLOC_SO" "$ALLOC_SRC" -ldl; then
        TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
        cat > "$TMPFILE" << 'EIGS'
t is 5
define f(flag) as:
    if flag == 0:
        local t is 1
EIGS
        i=1
        while [ "$i" -lt 64 ]; do
            printf '    elif flag == %s:\n        t is 2\n' "$i" >> "$TMPFILE"
            i=$((i + 1))
        done
        cat >> "$TMPFILE" << 'EIGS'
    else:
        t is 2
    return t
EIGS
        set +e
        OUTPUT=$(LD_PRELOAD="$ALLOC_SO" "$EIGS" --lint --lint-level error "$TMPFILE" 2>&1)
        LINT_STATUS=$?
        set -e
        check_status "W023 allocation failure linter survives" "$LINT_STATUS" "0"
        check_contains "W023 allocation hook reached the second leg" "$OUTPUT" "W023_ALLOC_HOOK_FAILED"
        check_not_contains "W023 allocation failure suppresses warning" "$OUTPUT" "W023]:"
        rm -f "$TMPFILE"
    else
        echo "  FAIL: W023 allocation-failure helper did not compile (not RED evidence)"
        FAIL=$((FAIL + 1))
        TOTAL=$((TOTAL + 1))
    fi
    rm -f "$ALLOC_SRC" "$ALLOC_SO"
fi

# Deliberate fail-safe false negative: an enclosing catch binder may own the
# name, so the nested function's genuine module mutation remains unreported.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
# Known false negative, DELIBERATE (maintainer ruling on #870, 2026-08-16):
# the enclosing catch t: env-binds t in f, so no write to t inside f's
# subtree is provably module-bound; the runtime walk may land in f's env
# (when the catch ran). Here the try never raises, g's bare t is 2 walks
# past f to the module and genuinely mutates it (5 -> 2), and W023 stays
# silent. Fail-safe is the accepted cost; do not reintroduce binder lists.
t is 5
define f(flag) as:
    define g(flag) as:
        if flag == 1:
            local t is 1
        else:
            t is 2
        return t
    try:
        print of (str of (g of 0))
    catch t:
        print of "nope"
    return 0
f of 0
print of ("module t is now " + (str of t))
EIGS
RUN=$($EIGS "$TMPFILE" 2>&1 || true)
check_contains "W023 false negative runtime changes module t" "$RUN" "module t is now 2"
OUTPUT=$($EIGS --lint --lint-level error "$TMPFILE" 2>&1) && LINT_STATUS=0 || LINT_STATUS=$?
check_status "W023 silent: enclosing catch lint completes" "$LINT_STATUS" "0"
check_not_contains "W023 silent: enclosing catch false negative" "$OUTPUT" "W023"
rm -f "$TMPFILE"

# The module-binding precondition is load-bearing: without a module t, the
# bare write gets a function-local slot and the later module read is undefined.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define f(flag) as:
    if flag == 1:
        local t is 1
    else:
        t is 2
    return t
print of (str of (f of 0))
print of ("module t is now " + (str of t))
EIGS
RUN=$($EIGS "$TMPFILE" 2>&1 || true)
check_contains "W023 no-module runtime exposes undefined t" "$RUN" "undefined variable 't'"
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1) && LINT_STATUS=0 || LINT_STATUS=$?
check_status "W023 no-module lint reports its E003 status" "$LINT_STATUS" "1"
check_not_contains "W023 silent without a proven module binding" "$OUTPUT" "W023"
check_contains "W023 no-module control keeps E003" "$OUTPUT" "E003.*undefined name 't'"
rm -f "$TMPFILE"

# Boundary: one `if`, 63 `elif` arms, and a terminal `else` is 65 branch
# bodies.  The parser accepts this family; W023 must scan it without a
# fixed-array overrun and report the real outer mutation normally.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
t is 5
define f(flag) as:
    if flag == 0:
        local t is 1
EIGS
i=1
while [ "$i" -lt 64 ]; do
    printf '    elif flag == %s:\n        t is 2\n' "$i" >> "$TMPFILE"
    i=$((i + 1))
done
cat >> "$TMPFILE" << 'EIGS'
    else:
        t is 2
    return t
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1) && LINT_STATUS=0 || LINT_STATUS=$?
check_status "W023 64-arm family lint returns a warning result" "$LINT_STATUS" "1"
check_contains "W023 64-arm family reaches the diagnostic" "$OUTPUT" "warning\[W023\]: 't'"
rm -f "$TMPFILE"

# The proof state must not silently discard a real binder after 512 names.
# `local t` is the 513th distinct name, so the sibling bare write is still
# function-local at runtime and W023 must fail safe to silence.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
t is 5
define f(flag) as:
EIGS
i=0
while [ "$i" -lt 512 ]; do
    printf '    local x%03d is 0\n' "$i" >> "$TMPFILE"
    i=$((i + 1))
done
cat >> "$TMPFILE" << 'EIGS'
    local t is 1
    if flag == 1:
        local t is 2
    else:
        t is 3
    return t
print of ("saturation return is " + (str of (f of 0)))
print of ("saturation module t is " + (str of t))
EIGS
RUN=$($EIGS "$TMPFILE" 2>&1) && RUN_STATUS=0 || RUN_STATUS=$?
check_status "W023 saturation runtime completes" "$RUN_STATUS" "0"
check_contains "W023 saturation keeps the return local" "$RUN" "^saturation return is 3$"
check_contains "W023 saturation leaves module t unchanged" "$RUN" "^saturation module t is 5$"
OUTPUT=$($EIGS --lint --lint-level error "$TMPFILE" 2>&1) && LINT_STATUS=0 || LINT_STATUS=$?
check_status "W023 saturation lint exits successfully" "$LINT_STATUS" "0"
check_not_contains "W023 silent after proof-state saturation" "$OUTPUT" "W023"
rm -f "$TMPFILE"

# Recursive control-flow proof frames must stay below the EigenOS stack
# contract.  Exercise nested AST_IF descent under an explicit 64 KiB stack
# limit and require a normal, silent lint result.
if [ "${EIGS_W023_STACK_PROBE:-0}" = 1 ]; then
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
t is 5
define f(flag) as:
    local t is 1
EIGS
indent='    '
i=0
while [ "$i" -lt 18 ]; do
    printf '%sif 1 == 1:\n' "$indent" >> "$TMPFILE"
    indent="${indent}    "
    i=$((i + 1))
done
printf '%sif flag == 1:\n' "$indent" >> "$TMPFILE"
printf '%s    local t is 2\n' "$indent" >> "$TMPFILE"
printf '%selse:\n' "$indent" >> "$TMPFILE"
printf '%s    t is 3\n' "$indent" >> "$TMPFILE"
cat >> "$TMPFILE" << 'EIGS'
    return t
EIGS
STACK_OUTPUT=$( (ulimit -s 64; "$EIGS" --lint --lint-level error "$TMPFILE" 2>&1) ) && STACK_STATUS=0 || STACK_STATUS=$?
check_status "W023 nested control flow completes under 64 KiB" "$STACK_STATUS" "0"
check_not_contains "W023 nested control flow stays silent" "$STACK_OUTPUT" "W023"
rm -f "$TMPFILE"
fi

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

# Fires inside a temporal qualifier — BOTH `at <expr>` and `when <expr>` (#868).
# The lint walkers descend into the interrogative's qualifier expression, and a
# new qualifier field is exactly the kind of addition they silently skip: six
# separate walkers in lint.c carry the descent, none of which the compiler
# would flag for missing a case. `when` shipped with all six unpatched and a
# typo'd ordinal name linted clean while the `at` twin errored.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
x is 1
x is 2
print of (what is x at nope_at)
print of (what is x when nope_when)
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "E003 fires inside an 'at' qualifier" "$OUTPUT" "undefined name 'nope_at'"
check_contains "E003 fires inside a 'when' qualifier (#868)" "$OUTPUT" "undefined name 'nope_when'"
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

# The corpus fixture keeps this host-only block reachable outside temporary
# shell data: its W017 is silenced only by the sibling eigs.json allow-list.
FIXTURE="$TESTS_DIR/lint_fixtures/eigs_json_allow.eigs"
OUT_FIXTURE=$($EIGS --lint "$FIXTURE" 2>&1 || true)
check_not_contains "#455 persistent corpus fixture exercises eigs.json allow-list" \
    "$OUT_FIXTURE" "W017"

# --- #556: W013 is attributed to the define line itself ---
# The warning used to land on the first statement AFTER the shadowing define
# (p_cur had advanced past the body), so a same-line `# lint: allow W013` on
# the define never matched and consecutive shadows chain-suppressed each other.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
_real is remove_file
define remove_file(path) as:
    return _real of path
r is remove_file of "/nonexistent"
print of r
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#556 W013 reported at the define line (2)" "$OUTPUT" ":2: warning\[W013\]"
check_not_contains "#556 W013 not attributed to the next statement (4)" "$OUTPUT" ":4: warning\[W013\]"
rm -f "$TMPFILE"

TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
_real is remove_file
define remove_file(path) as:   # lint: allow W013
    return _real of path
r is remove_file of "/nonexistent"
print of r
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "#556 same-line allow pragma on the define suppresses W013" "$OUTPUT" "W013"
rm -f "$TMPFILE"

# Consecutive shadowing defines: each warns on its OWN define line (the old
# attribution made each define's warning land on the NEXT define, where that
# define's pragma chain-suppressed it).
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
_r1 is remove_file
_r2 is rename
define remove_file(path) as:
    return _r1 of path
define rename(args) as:
    return _r2 of args
x is remove_file of "/nonexistent"
y is rename of ["/a", "/b"]
print of x
print of y
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#556 first of two consecutive shadows warns (line 3)" "$OUTPUT" ":3: warning\[W013\]"
check_contains "#556 second of two consecutive shadows warns (line 5)" "$OUTPUT" ":5: warning\[W013\]"
rm -f "$TMPFILE"

# --- #583 (W019): statement-level interrogative discards its result ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define f(e) as:
    local why is "init failed"
    if e == 1:
        why is "no builtins"
    return why
print of (f of 1)
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#583 W019 fires on statement-level 'why is ...'" "$OUTPUT" "W019"
check_contains "#583 W019 reported at the interrogative's line (4)" "$OUTPUT" ":4: warning\[W019\]"
rm -f "$TMPFILE"

TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
x is 5
x is 7
prev of x
print of x
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#583 W019 fires on statement-level 'prev of'" "$OUTPUT" "W019"
rm -f "$TMPFILE"

TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
x is 5
x is 7
print of (what is x)
p is prev of x
print of p
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "#583 interrogatives inside expressions are not flagged" "$OUTPUT" "W019"
rm -f "$TMPFILE"

# --- #736 (W019): a bare observer query as a statement prints nothing ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
x is 100.0
x is 50.0
report of x
observe of x
report_value of x
trajectory of x
print of x
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#736 W019 fires on bare 'report of x' (line 3)" "$OUTPUT" ":3: warning\[W019\]"
check_contains "#736 W019 fires on bare 'observe of x' (line 4)" "$OUTPUT" ":4: warning\[W019\]"
check_contains "#736 W019 fires on bare 'report_value of x' (line 5)" "$OUTPUT" ":5: warning\[W019\]"
check_contains "#736 W019 fires on bare 'trajectory of x' (line 6)" "$OUTPUT" ":6: warning\[W019\]"
rm -f "$TMPFILE"

TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
x is 100.0
x is 50.0
print of (report of x)
s is report of x
o is observe of x
print of s
print of o[0]
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "#736 observer queries inside expressions are not flagged" "$OUTPUT" "W019"
rm -f "$TMPFILE"

# --- #655 (W020): an unobserved: block that provably does nothing ---
# The positive is the shape our own README shipped for two months. The
# negatives are what keep the rule honest: each is a block that LOOKS inert
# but is load-bearing, and a rule that flagged any of them would be worse
# than no rule — it would teach people to delete real optimisations.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
game is {"px": 0.0, "vx": 1.0}
unobserved:
    game.px is game.px + game.vx * 0.1
print of game.px
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#655 W020 fires on a dict-only unobserved block" "$OUTPUT" "W020"
check_contains "#655 W020 reported at the block's line (2)" "$OUTPUT" ":2: warning\[W020\]"
rm -f "$TMPFILE"

TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
xs is [1.0, 2.0]
unobserved:
    xs[0] is xs[0] + 1.0
print of xs[0]
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#655 W020 fires on an index-only unobserved block" "$OUTPUT" "W020"
rm -f "$TMPFILE"

# A plain variable is the real optimisation — never flag it.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
acc is 0.0
i is 0
unobserved:
    loop while i < 10:
        acc is acc + 1.0
        i is i + 1
print of acc
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "#655 a plain-variable unobserved block is not flagged" "$OUTPUT" "W020"
rm -f "$TMPFILE"

# Mixed (Tidepool's real physics shape): dict writes AND named locals. The
# named half is doing the work, so the block stays.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
game is {"px": 0.0}
cx is 0.0
unobserved:
    cx is cx + 1.0
    game.px is game.px + cx
print of game.px
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "#655 a mixed dict+named unobserved block is not flagged" "$OUTPUT" "W020"
rm -f "$TMPFILE"

# The subtle one: g_unobserved_depth is GLOBAL, so the callee runs unobserved
# too and its named assignments are skipped. Every target in view is a dict
# field, yet the block is load-bearing. Verified: `when is y` inside f reads 3
# normally and 0 when f is called from inside a block.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define f(n) as:
    y is n + 1
    y is y * 2
    return y
game is {"px": 0.0}
unobserved:
    game.px is f of 1
print of game.px
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "#655 a block whose callee assigns names is not flagged" "$OUTPUT" "W020"
rm -f "$TMPFILE"

# A for-loop binds its variable by name — that binding takes the named path.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
game is {"px": 0.0}
unobserved:
    for step in [1, 2, 3]:
        game.px is game.px + step
print of game.px
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "#655 a block binding a for-loop variable is not flagged" "$OUTPUT" "W020"
rm -f "$TMPFILE"

# --- #591: W021 hint when a define shadows a PUBLIC stdlib function the ---
# --- file never imported (sibling of W013 for the lib/*.eigs layer)     ---
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define median(vals) as:
    return vals[0]
print of (median of [3, 1, 2])
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#591 hint fires on un-imported stdlib shadow, naming the module" "$OUTPUT" "hint\[W021\]: define 'median' shadows lib/stats.eigs 'median' (import stats to use it)"
rm -f "$TMPFILE"

# Hint severity never fails --lint, under either --lint-level.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define median(vals) as:
    return vals[0]
print of (median of [3, 1, 2])
EIGS
RC_H=0; $EIGS --lint "$TMPFILE" >/dev/null 2>&1 || RC_H=$?
RC_HE=0; $EIGS --lint --lint-level error "$TMPFILE" >/dev/null 2>&1 || RC_HE=$?
[ "$RC_H" -eq 0 ] && { echo "  PASS: #591 hint-only file exits 0 (default level)"; PASS=$((PASS+1)); } || { echo "  FAIL: #591 hint-only default-level exit was $RC_H"; FAIL=$((FAIL+1)); }
[ "$RC_HE" -eq 0 ] && { echo "  PASS: #591 hint-only file exits 0 (--lint-level error)"; PASS=$((PASS+1)); } || { echo "  FAIL: #591 hint-only error-level exit was $RC_HE"; FAIL=$((FAIL+1)); }
TOTAL=$((TOTAL+2))
rm -f "$TMPFILE"

# Importing the module makes the shadow deliberate: no hint.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
import stats
define median(vals) as:
    return vals[0]
print of (median of [3, 1, 2])
print of (stats.median of [3, 1, 2])
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "#591 no hint when the module is imported" "$OUTPUT" "W021"
rm -f "$TMPFILE"

# A name that is BOTH a builtin and a lib public stays W013-only (no
# double-report from the sibling rule).
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define mean(vals) as:
    return vals[0]
m is mean of [1]
print of m
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#591 builtin-overlapping name still gets W013" "$OUTPUT" "W013"
check_not_contains "#591 builtin-overlapping name gets no W021 (W013's territory)" "$OUTPUT" "W021"
rm -f "$TMPFILE"

# Same-line allow pragma suppresses the hint (mirrors the #556 W013 test).
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define median(vals) as:   # lint: allow W021
    return vals[0]
print of (median of [3, 1, 2])
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "#591 same-line '# lint: allow W021' suppresses the hint" "$OUTPUT" "W021"
rm -f "$TMPFILE"

# Per-file eigs.json allow-list suppresses the hint (mirrors the #455 test).
LINTPKG=$(mktemp -d /tmp/lint_pkg_XXXXXX)
mkdir -p "$LINTPKG/src"
printf 'define median(vals) as:\n    return vals[0]\nprint of (median of [3, 1, 2])\n' > "$LINTPKG/src/shadow.eigs"
printf '{ "lint": { "allow": { "src/shadow.eigs": ["W021"] } } }\n' > "$LINTPKG/eigs.json"
OUT_ALLOW=$($EIGS --lint "$LINTPKG/src/shadow.eigs" 2>&1 || true)
check_not_contains "#591 eigs.json allow-list suppresses the hint" "$OUT_ALLOW" "W021"
printf '{ "lint": { "allow": { "src/shadow.eigs": ["W003"] } } }\n' > "$LINTPKG/eigs.json"
OUT_WRONG=$($EIGS --lint "$LINTPKG/src/shadow.eigs" 2>&1 || true)
check_contains "#591 allowing a different code leaves the hint firing" "$OUT_WRONG" "W021"
rm -rf "$LINTPKG"

# A module never hints against its own defines (self-lint guard).
LINTPKG=$(mktemp -d /tmp/lint_pkg_XXXXXX)
mkdir -p "$LINTPKG/lib"
printf 'define w021_selfname(x) as:\n    return x\nprint of (w021_selfname of 1)\n' > "$LINTPKG/lib/selfmod.eigs"
OUTPUT=$($EIGS --lint "$LINTPKG/lib/selfmod.eigs" 2>&1 || true)
check_not_contains "#591 a module never hints against its own defines" "$OUTPUT" "W021"
rm -rf "$LINTPKG"

# --- #784/#785: W012/W013 recurse into unobserved blocks and match arms ---
# check_builtin_shadow used to break on AST_UNOBSERVED/AST_MATCH, so shadows
# inside those scopes lint'd clean while top-level ones warned.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
unobserved:
    chr is 7
print of "hi"
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#784 W012 fires inside an unobserved block" "$OUTPUT" "W012.*'chr'"
rm -f "$TMPFILE"

TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
match 1:
    case 1:
        chr is 7
print of "hi"
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#784 W012 fires inside a match arm" "$OUTPUT" "W012.*'chr'"
rm -f "$TMPFILE"

TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
unobserved:
    define chr(a) as:
        return a
print of "hi"
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#785 W013 fires inside an unobserved block" "$OUTPUT" "W013.*'chr'"
rm -f "$TMPFILE"

TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
match 1:
    case 1:
        define chr(a) as:
            return a
print of "hi"
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#785 W013 fires inside a match arm" "$OUTPUT" "W013.*'chr'"
rm -f "$TMPFILE"

# --- #780: W001 (unused variable) recurses into match arms ---
# collect_assigns used to break on AST_MATCH, so a variable assigned only
# inside a match arm was never recorded and never warned on.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
match 1:
    case 1:
        w001_inmatch is 5
print of "done"
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#780 W001 fires inside a match arm" "$OUTPUT" "W001.*'w001_inmatch'"
rm -f "$TMPFILE"

TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
match 2:
    case 1:
        print of "one"
    case _:
        w001_inmatch2 is 6
print of "done"
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "#780 W001 fires in the fallback match arm" "$OUTPUT" "W001.*'w001_inmatch2'"
rm -f "$TMPFILE"
rm -f "$TMPFILE"

# --- W022 (#733): literal arg list longer than the callee's params ---
# Over-arity is silent at runtime (two of [1, 2, 99] drops 99, rc=0);
# W022 fires only when the callee name provably has one meaning in the
# file (one define, no other binding).

TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define two(a, b) as:
    return a + b
print of (two of [1, 2, 99])
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "W022 fires on over-arity to a unique define" "$OUTPUT" "W022.*passes 3 arguments but 'two' takes 2"
rm -f "$TMPFILE"

TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define one(a) as:
    return a
define two(a, b) as:
    return a + b
print of (one of [5, 6])
print of (two of [1, 2])
print of (two of ([1, 2, 3]))
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "W022 silent: 1-param variadic, exact arity, parenthesized" "$OUTPUT" "W022"
rm -f "$TMPFILE"

TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define two(a, b) as:
    return a + b
two is 7
x is two of [1, 2, 99]
print of x
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "W022 silent when the name is rebound (poisoned)" "$OUTPUT" "W022"
rm -f "$TMPFILE"

TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define dup(a, b) as:
    return a
define dup(a, b, c) as:
    return a
y is dup of [1, 2, 3, 4]
print of y
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_not_contains "W022 silent when the name is defined twice" "$OUTPUT" "W022"
rm -f "$TMPFILE"

# NOTE: there is no 0-param case — `define f()` / `define f` both get the
# implicit single param `n` (parser.c), so every define has arity >= 1 and
# the arity-1 whole-list exemption covers the "no params" shape too.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define three(a, b, c is 9) as:
    return a + b + c
print of (three of [1, 2, 3, 4])
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1 || true)
check_contains "W022 counts defaulted params in the arity" "$OUTPUT" "W022.*passes 4 arguments but 'three' takes 3"
rm -f "$TMPFILE"

# --- Compile-stage errors reach the lint surface (#927) ---
#
# Lint stopped at the parser, so the one defect no style rule can outrank —
# the compiler REFUSES this file — was the one thing it stayed silent about:
# `--lint` printed "no issues found" and exited 0 while running the same file
# aborted. The invariant under test is not any single compile error: NO input
# that fails to compile may report success, whatever the compile error is.
# Compilation is not execution (imports and load_file are runtime ops), so
# lint still never runs the program.
check_noncompiling() {
    local label="$1" file="$2" msg="$3"
    local out rc
    out=$($EIGS --lint "$file" 2>&1) && rc=0 || rc=$?
    check_status "$label exits 1" "$rc" "1"
    check_contains "$label names the compile error" "$out" "$msg"
    check_not_contains "$label does not claim a clean file" "$out" "no issues found"
}

# (a) expression nesting too deep — built here rather than committed, and in
# shell rather than python3, so this file keeps running standalone. An
# f-string costs ~2 nesting levels per interpolation (#912), so 63 of them
# clear the 128-level limit.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
PARTS=""
i=0
while [ "$i" -lt 63 ]; do PARTS="${PARTS}a${i}={x}"; i=$((i + 1)); done
printf 'x is 1\nprint of f"%s"\n' "$PARTS" > "$TMPFILE"
check_noncompiling "too-deep expression" "$TMPFILE" "expression nesting too deep"

# The machine surface has to agree with the exit code, or a --json consumer
# reads an empty diagnostic array beside a failing status.
OUTPUT=$($EIGS --lint --json "$TMPFILE" 2>/dev/null || true)
check_contains "too-deep expression is an E004 error in --json" "$OUTPUT" \
    '"code":"E004","severity":"error"'

# Error-severity diagnostics fail under both levels — --lint-level error
# makes WARNINGS advisory, not errors.
OUTPUT=$($EIGS --lint --lint-level error "$TMPFILE" 2>&1) && RC=0 || RC=$?
check_status "non-compiling file fails --lint-level error too" "$RC" "1"
rm -f "$TMPFILE"

# (b) a different compile error entirely: `break` with no loop to break.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
x is 1
break
print of x
EIGS
check_noncompiling "'break' outside a loop" "$TMPFILE" "'break' outside a loop"
rm -f "$TMPFILE"

# (c) and its sibling, so the guard is on the class and not on one message.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
x is 1
continue
print of x
EIGS
check_noncompiling "'continue' outside a loop" "$TMPFILE" "'continue' outside a loop"
rm -f "$TMPFILE"

# The other half of the invariant: a file that DOES compile still passes.
# Without this, "always exit 1" would satisfy everything above.
TMPFILE=$(mktemp /tmp/lint_test_XXXXXX.eigs)
cat > "$TMPFILE" << 'EIGS'
define pick(a, b) as:
    if a > b:
        return a
    else:
        return b
n is 0
loop while n < 3:
    n is n + 1
    if n == 2:
        continue
print of (pick of [n, 7])
EIGS
OUTPUT=$($EIGS --lint "$TMPFILE" 2>&1) && RC=0 || RC=$?
check_status "compiling file still exits 0" "$RC" "0"
check_contains "compiling file still reports clean" "$OUTPUT" "no issues found"
rm -f "$TMPFILE"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
exit $FAIL
