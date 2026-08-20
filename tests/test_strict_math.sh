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

# NOTE: <expect-substr> must never be the empty string — `grep -qF ""` matches
# any output, so an empty expectation silently degrades the row to an exit-code
# check. Rows asserting an EMPTY result wrap it (`f"[{...}]"` against "[]") so
# the emptiness is something the assertion can actually see.
#
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

# --- #971 Phase A: argument TYPE guards, same gate ---------------------------
# ~34 builtins answered a wrong-typed argument with a soft stand-in, so a type
# mistake became a plausible value: `cos of "hello"` was 0, `str_upper of 42`
# was "". Off by default that is unchanged (SM11/SM12 pin it); under strict it
# raises a catchable `type` error naming the builtin.
run "SM11 default cos(str) still 0"    unset 0 "0"    'print of (cos of "hello")'
run "SM12 default str_upper(num) is empty" unset 0 "[]" 'print of f"[{str_upper of 42}]"'
run "SM13 strict cos(str) raises"      1 1 "cos: expected a number"        'print of (cos of "hello")'
run "SM14 strict str_upper(num) raises" 1 1 "str_upper: expected a string" 'print of (str_upper of 42)'
run "SM15 strict arity guard raises"   1 1 "substr: expected"              'print of (substr of 42)'
run "SM16 strict type raise is catchable" 1 0 "caught type" \
'try:
    x is cos of "hello"
catch e:
    print of f"caught {e.kind}"'
run "SM17 strict leaves valid args alone" 1 0 "1"                          'print of (cos of 0)'

# The exclusions matter as much as the conversions: these 0s are DOCUMENTED
# RETURN VALUES, not fail-soft guards, so strict must NOT make them raise.
# A sed over `return make_num(0)` would have broken both.
run "SM18 strict: try_parse(bad) still answers 0" 1 0 "0"  'print of (try_parse of "!!!")'
run "SM19 strict: unknown task id still not alive" 1 0 "0" 'print of (task_alive of 99999)'

# --- #971 Phase B: the ELEMENT-type guards -----------------------------------
# Phase A converted the outer ARITY guards and left the inner element-type
# checks soft, so a call with the right shape and the wrong element types was
# still silently answered. `contains of [[1,2,3], 2]` is the sharp one: the
# function's own comment describes that spurious-hit bug as fixed, while the
# type mistake behind it stayed quiet.
run "SM20 strict contains(list, num) raises"  1 1 "contains: expected two strings" \
    'print of (contains of [[1, 2, 3], 2])'
run "SM21 strict char_at(num, i) raises"      1 1 "char_at: expected"    'print of (char_at of [42, 0])'
run "SM22 strict substr element type raises"  1 1 "substr: expected"     'print of (substr of [42, 0, 1])'
run "SM23 strict has_key(num, k) raises"      1 1 "has_key: expected"    'print of (has_key of [42, "k"])'
run "SM24 strict max over a non-number raises" 1 1 "max: expected"       'print of (max of [1, "x", 3])'
run "SM25 strict path_join element type raises" 1 1 "path_join: expected" 'print of (path_join of [42, "b"])'
# NB: the builtin is `add`, not `tensor_add` — the first version of this row
# named a builtin that does not exist, and "undefined variable" is also rc=1.
# It failed only because this row asserts on the MESSAGE as well as the exit
# code; the differential's rc-only check scored the same mistake as coverage
# until it grew the same assertion.
run "SM26 strict elementwise add element type raises" 1 1 "expected"    'print of (add of ["x", 1])'
run "SM27 strict write_bytes type raises"     1 1 "write_bytes: expected" 'print of (write_bytes of 42)'

# str_replace COERCES rather than returning a stand-in — a non-string element
# silently became "" and the search ran over an empty string. It has no
# `return make_num(0)` to convert, so it is invisible to the classifier and
# needed STRICT_REQUIRE (raise under strict, no-op otherwise). Found by the
# differential, not by the classifier: SM29 is why both harnesses exist.
run "SM28 default str_replace(num,..) unchanged" unset 0 "[]" \
'local r is str_replace of [42, "a", "b"]
print of f"[{r}]"'
run "SM29 strict str_replace coercion raises"  1 1 "str_replace: expected a string" \
    'print of (str_replace of [42, "a", "b"])'

# More exclusion pins. These grew with the conversion set on purpose: without
# them, converting EVERYTHING would score a perfect "raises under strict" and
# the reform would have no failure mode at all.
run "SM30 strict: ends_with, suffix too long, still 0" 1 0 "0" 'print of (ends_with of ["ab", "abc"])'
run "SM31 strict: char_at past the end still empty"    1 0 "[]" \
'local r is char_at of ["ab", 9]
print of f"[{r}]"'
run "SM32 strict: join of an empty list still empty"   1 0 "[]" \
'local r is join of [[], ","]
print of f"[{r}]"'
run "SM33 strict: num still COERCES a list to 0"       1 0 "0" 'print of (num of ([1, 2]))'
run "SM34 strict: list_contains finding nothing is 0"  1 0 "0" 'print of (list_contains of [[1, 2], 9])'
run "SM35 strict: JSON false still decodes to 0"       1 0 "0" \
    'print of (json_path of ["{\"a\": false}", "a"])'

echo "STRICT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
