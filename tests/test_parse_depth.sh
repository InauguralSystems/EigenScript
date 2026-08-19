#!/bin/bash
# Regression: deeply nested prefix (`not`/`-`/`~`) and right-recursive `of`
# expressions must hit the parser depth guard and exit cleanly, never overflow
# the C stack (SIGSEGV rc 139). These recursion families bypassed the
# parse-depth guard before — a single malformed line crashed the runtime, which
# a public language must never do. A clean parse-error exit (rc 1) is correct.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$TESTS_DIR/.." && pwd)/src/eigenscript"
FAILURES=0

check_no_crash() {
    local name="$1" prog="$2"
    local f; f=$(mktemp /tmp/eigs_pd_XXXXXX.eigs)
    printf '%s' "$prog" > "$f"
    "$BIN" "$f" >/dev/null 2>&1; local rc=$?
    rm -f "$f"
    # 139 = SIGSEGV (stack overflow), 134 = SIGABRT. Anything else (0/1) is a
    # clean handle.
    if [ $rc -eq 139 ] || [ $rc -eq 134 ]; then
        echo "  FAIL: $name (crash rc=$rc)"
        FAILURES=$((FAILURES + 1))
    else
        echo "  PASS: $name (clean rc=$rc, no crash)"
    fi
}

check_no_crash "unary 'not' nesting bomb" "x is $(printf 'not %.0s' $(seq 1 50000))1"
check_no_crash "unary '-' nesting bomb"   "x is $(printf -- '-%.0s' $(seq 1 200000))1"
check_no_crash "'of' relation nesting bomb" "x is $(printf 'f of %.0s' $(seq 1 100000))1"
check_no_crash "mixed prefix nesting bomb" "x is $(printf 'not -~%.0s' $(seq 1 40000))1"

# Iterative chains (postfix accessors, left-assoc binops) build a deep AST
# without recursing, so they bypassed the parse-depth guard and overflowed the
# recursive compiler / free_ast walkers — a distinct vector from the prefix
# bombs above. They must be bounded, not crash.
check_no_crash "postfix index chain bomb"  "x is a$(printf '[0]%.0s' $(seq 1 1000))"
check_no_crash "postfix dot chain bomb"    "x is a$(printf '.b%.0s' $(seq 1 100000))"
check_no_crash "binop '+' chain bomb"      "x is 1$(printf '+1%.0s' $(seq 1 100000))"
check_no_crash "binop '&' chain bomb"      "x is 1$(printf '&1%.0s' $(seq 1 100000))"
check_no_crash "logical 'and' chain bomb"  "x is 1$(printf ' and 1%.0s' $(seq 1 100000))"

# --- #926: an elif chain recurses in C despite being syntactically flat ----
# Charge the shared parser budget before descending into the next arm. The
# bound must stop the chain with the same small diagnostic set at 300 arms and
# at the historical 14,000-arm stack-exhaustion input; a guard deletion must
# therefore fail by the exact-count/ceiling assertions below, not by a crash.
gen_elif_chain() {
    local arms="$1" file="$2" i
    {
        printf '%s\n' 'x is 0' 'if x == 0:' '    print of 0'
        i=1
        while [ "$i" -lt "$arms" ]; do
            printf 'elif x == %d:\n    print of %d\n' "$i" "$i"
            i=$((i + 1))
        done
        printf '%s\n' 'else:' '    print of -1'
    } > "$file"
}

check_elif_contract() {
    local name="$1" mode="$2" file="$3" want_errors="$4" max_lines="$5"
    local rc stderr_lines got_errors
    if [ "$mode" = lint ]; then
        "$BIN" --lint "$file" >"$ELIF_TMP/stdout" 2>"$ELIF_TMP/stderr"
    else
        "$BIN" "$file" >"$ELIF_TMP/stdout" 2>"$ELIF_TMP/stderr"
    fi
    rc=$?
    stderr_lines=$(awk 'END { print NR + 0 }' "$ELIF_TMP/stderr")
    got_errors=$(awk '
        match($0, /[0-9]+ parse error\(s\)/) {
            value = substr($0, RSTART, RLENGTH)
            sub(/ parse error\(s\)/, "", value)
            count = value + 0
        }
        END { print count + 0 }
    ' "$ELIF_TMP/stderr")
    if [ "$rc" -eq 1 ] && [ "$got_errors" -eq "$want_errors" ] &&
       [ "$stderr_lines" -le "$max_lines" ]; then
        echo "  PASS: $name (rc=$rc, errors=$got_errors, stderr_lines=$stderr_lines)"
    else
        echo "  FAIL: $name (rc=$rc, errors=$got_errors, stderr_lines=$stderr_lines, wanted rc=1, errors=$want_errors, stderr_lines<=$max_lines)"
        sed -n '1,3p' "$ELIF_TMP/stderr" | sed 's/^/    /'
        FAILURES=$((FAILURES + 1))
    fi
}

check_lint_no_parse_diagnostics() {
    local name="$1" file="$2" want_compile_errors="$3"
    local rc stderr_lines compile_errors parse_diagnostics
    "$BIN" --lint "$file" >"$ELIF_TMP/stdout" 2>"$ELIF_TMP/stderr"
    rc=$?
    stderr_lines=$(awk 'END { print NR + 0 }' "$ELIF_TMP/stderr")
    compile_errors=$(awk '
        match($0, /[0-9]+ compile error\(s\) \[E004\]/) {
            value = substr($0, RSTART, RLENGTH)
            sub(/ compile error\(s\) \[E004\]/, "", value)
            count = value + 0
        }
        END { print count + 0 }
    ' "$ELIF_TMP/stderr")
    parse_diagnostics=$(awk '/Parse error line|parse error\(s\) \[E002\]/ { count++ } END { print count + 0 }' "$ELIF_TMP/stderr")
    if [ "$rc" -eq 1 ] && [ "$compile_errors" -eq "$want_compile_errors" ] &&
       [ "$parse_diagnostics" -eq 0 ]; then
        echo "  PASS: $name (rc=$rc, compile_errors=$compile_errors, parse_diagnostics=0, stderr_lines=$stderr_lines)"
    else
        echo "  FAIL: $name (rc=$rc, compile_errors=$compile_errors, parse_diagnostics=$parse_diagnostics, stderr_lines=$stderr_lines, wanted rc=1, compile_errors=$want_compile_errors, parse_diagnostics=0)"
        sed -n '1,3p' "$ELIF_TMP/stderr" | sed 's/^/    /'
        FAILURES=$((FAILURES + 1))
    fi
}

ELIF_TMP=$(mktemp -d /tmp/eigs_elif_XXXXXX)
gen_elif_chain 300 "$ELIF_TMP/c300.eigs"
check_elif_contract "300-arm chain: plain mode has the bounded PARSE diagnostic" plain \
    "$ELIF_TMP/c300.eigs" 8 12
check_elif_contract "300-arm chain: --lint has the bounded PARSE diagnostic" lint \
    "$ELIF_TMP/c300.eigs" 8 12

# A second chain must start with the statement-entry depth, not the first
# chain's charged depth. Current lint compiles these sub-bound chains, so this
# asserts exactly two compiler refusals and no parser-stage diagnostic.
gen_elif_chain 200 "$ELIF_TMP/c200.eigs"
cat "$ELIF_TMP/c200.eigs" "$ELIF_TMP/c200.eigs" > "$ELIF_TMP/two_chains.eigs"
check_lint_no_parse_diagnostics \
    "two 200-arm chains: arm depth does not leak across statements" \
    "$ELIF_TMP/two_chains.eigs" 14

# Keep the original crash-length reproducer in the runner regression. The
# short RED pass used for the TDD gate sets this to 0 because the unguarded
# historical parser can exhaust the local shell's C stack; the 300-arm case
# above still fails by assertion for the missing guard.
if [ "${EIGS_PARSE_DEPTH_RUN_LONG:-1}" -eq 1 ]; then
    gen_elif_chain 14000 "$ELIF_TMP/c14000.eigs"
    check_elif_contract "14,000-arm chain: plain mode stays bounded" plain \
        "$ELIF_TMP/c14000.eigs" 8 12
    check_elif_contract "14,000-arm chain: --lint stays bounded" lint \
        "$ELIF_TMP/c14000.eigs" 8 12
fi

rm -rf "$ELIF_TMP"

echo ""
exit "$FAILURES"
