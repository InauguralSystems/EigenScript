#!/bin/bash
# #971: strict math mode (EIGS_STRICT). Off by default the arithmetic is
# finite-by-construction (domain ops substitute a stand-in + set the invalid
# flag); on, an out-of-domain op RAISES an EK_VALUE error instead.
# Run directly or from run_all_tests.sh. Prints: STRICT: N passed, M failed
# Exit code: 0 if all pass, 1 if any fail.

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$(cd "$TESTS_DIR/.." && pwd)/src/eigenscript"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

if [ ! -x "$EIGS" ]; then
    echo "  FAIL: eigenscript binary not found at $EIGS"
    echo "STRICT: 0 passed, 1 failed"
    exit 1
fi

TMP=$(mktemp /tmp/eigs_strict_XXXXXX.eigs)
trap 'rm -f "$TMP"' EXIT

# run <name> <env: unset|0|1> <expect-exit 0|1> <expect-substr> <program>
run() {
    local name="$1" env="$2" xexit="$3" substr="$4" prog="$5"
    printf '%s\n' "$prog" > "$TMP"
    local out rc
    case "$env" in
        unset) out=$("$EIGS" "$TMP" 2>&1); rc=$? ;;
        *)     out=$(EIGS_STRICT="$env" "$EIGS" "$TMP" 2>&1); rc=$? ;;
    esac
    local exit_ok=0
    if [ "$xexit" = "0" ] && [ "$rc" = "0" ]; then exit_ok=1; fi
    if [ "$xexit" = "1" ] && [ "$rc" != "0" ]; then exit_ok=1; fi
    if [ "$exit_ok" = "1" ] && echo "$out" | grep -qF "$substr"; then
        ok "$name"
    else
        fail "$name" "rc=$rc out='$out'"
    fi
}

# --- Default (unset) and explicit EIGS_STRICT=0: finite-by-construction ---
run "SM01 default sqrt(-1) -> 0"      unset 0 "0"                      'print of (sqrt of -1)'
run "SM02 default asin(5) clamps"     unset 0 "1.57"                   'print of (asin of 5)'
run "SM03 EIGS_STRICT=0 is off"       0     0 "0"                      'print of (sqrt of -1)'

# --- Strict on: out-of-domain raises EK_VALUE ---
run "SM04 strict sqrt(-1) raises"     1 1 "sqrt: argument out of domain"  'print of (sqrt of -1)'
run "SM05 strict log(0) raises"       1 1 "log: argument out of domain"   'print of (log of 0)'
run "SM06 strict asin(5) raises"      1 1 "asin: argument out of domain"  'print of (asin of 5)'
run "SM07 strict acos(-2) raises"     1 1 "acos: argument out of domain"  'print of (acos of -2)'

# --- Strict error is catchable as kind "value" ---
run "SM08 strict raise is catchable"  1 0 "caught value" \
'try:
    x is sqrt of -1
catch e:
    print of f"caught {e.kind}"'

# --- Strict leaves valid inputs alone ---
run "SM09 strict valid sqrt(16)=4"    1 0 "4"                          'print of (sqrt of 16)'

# --- Strict covers the elementwise tensor path (tensor_unary) ---
run "SM10 strict tensor sqrt raises"  1 1 "out of domain"              'print of (sqrt of [4, -1, 9])'

echo "STRICT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
