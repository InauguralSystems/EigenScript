#!/bin/bash
# Regression: deeply nested prefix (`not`/`-`/`~`) and right-recursive `of`
# expressions must hit the parser depth guard and exit cleanly, never overflow
# the C stack (SIGSEGV rc 139). These recursion families bypassed the
# parse-depth guard before — a single malformed line crashed the runtime, which
# a public language must never do. A clean parse-error exit (rc 1) is correct.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$TESTS_DIR/.." && pwd)/src/eigenscript"

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

echo ""
