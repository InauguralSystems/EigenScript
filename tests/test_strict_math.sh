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

# LEAK-VISIBLE ROWS (#971 round 2). Every row captures stdout+stderr together,
# so when this file is driven by an ASan build with ASAN_OPTIONS=detect_leaks=1
# a LeakSanitizer report lands in "$out" and `leak_clean` turns the row RED.
# This exists because a strict raise ALREADY exits non-zero, so LeakSanitizer
# does not change the process status and a leaking guard looks exactly like an
# ordinary expected raise: three guards (scan_ints / scan_tokens /
# scan_int_tokens) leaked 1096 bytes each while all 85 rows reported PASS.
# Under a release build there is no such output and the check is a no-op, so
# the gate costs nothing and cannot go vacuous silently: it reads the same
# text the assertion already reads.
#
# NOTE: <expect-substr> must never be the empty string — `grep -qF ""` matches
# any output, so an empty expectation silently degrades the row to an exit-code
# check. Rows asserting an EMPTY result wrap it (`f"[{...}]"` against "[]") so
# the emptiness is something the assertion can actually see.
#
# run <name> <env: unset|0|1> <expect-exit 0|1> <expect-substr> <program>
# leak_clean <captured-output>: 1 unless LeakSanitizer reported on this run.
# Only ever non-empty under an ASan build with detect_leaks=1.
leak_clean() {
    case "$1" in
        *"LeakSanitizer: detected memory leaks"*) return 1 ;;
        *) return 0 ;;
    esac
}

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
    if ! leak_clean "$out"; then
        fail "$name" "LEAKED on this path: $(echo "$out" | grep -F 'SUMMARY: AddressSanitizer')"
    elif [ "$exit_ok" = "1" ] && echo "$out" | grep -qF -- "$substr"; then
        ok "$name"
    else
        fail "$name" "rc=$rc out='$out'"
    fi
}

# run_jitoff <name> <expect-substr> <program>: EIGS_STRICT=1 with the JIT off,
# expecting a raise — the interpreter half of the JIT/interpreter agreement.
run_jitoff() {
    local name="$1" substr="$2" prog="$3"
    printf '%s\n' "$prog" > "$TMP"
    local out rc
    out=$(EIGS_STRICT=1 EIGS_JIT_OFF=1 "$EIGS" "$TMP" 2>&1); rc=$?
    if ! leak_clean "$out"; then
        fail "$name" "LEAKED on this path: $(echo "$out" | grep -F 'SUMMARY: AddressSanitizer')"
    elif [ "$rc" != "0" ] && echo "$out" | grep -qF -- "$substr"; then
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

# --- #971 Phase C: JSON parse failure in json_path ----------------------------
# json_path walked a PARTIAL document and answered the same "" an absent key
# returns, so malformed JSON was indistinguishable from a missing field. Under
# strict the parse failure raises (json_decode's acceptance test: structural
# error, repaired scalar, trailing garbage) as a catchable `value` error naming
# the position. Off: byte-identical (SM36/SM37 pin the lenient walk). JSON
# `false`/`null`/absent-key are ANSWERS and stay quiet in both modes.
run "SM36 default json_path(bad number) still walks partial" unset 0 "[0]" \
    'print of f"[{json_path of ["{\"a\": 1e", "a"]}]"'
run "SM37 default json_path(truncated array) still partial" unset 0 "[[1,2]]" \
    'print of f"[{json_path of ["{\"a\": [1, 2", "a"]}]"'
run "SM38 strict json_path(bad number) raises with position" 1 1 "json_path: invalid JSON at position 8" \
    'print of (json_path of ["{\"a\": 1e", "a"])'
run "SM39 strict json_path(truncated) raises" 1 1 "json_path: invalid JSON at position" \
    'print of (json_path of ["{\"a\": [1, 2", "a"])'
run "SM40 strict json_path(trailing garbage) raises" 1 1 "json_path: invalid JSON at position 9" \
    'print of (json_path of ["{\"a\": 1} x", "a"])'
run "SM41 strict json_path(empty document) raises" 1 1 "json_path: invalid JSON at position 0" \
    'print of (json_path of ["", "a"])'
run "SM42 strict json_path raise is catchable as value" 1 0 "caught value" \
'try:
    x is json_path of ["{bad", "a"]
catch e:
    print of f"caught {e.kind}"'
run "SM43 strict: JSON false is still 0"                1 0 "0"  'print of (json_path of ["{\"a\": false}", "a"])'
run "SM44 strict: absent key is still empty"            1 0 "[]" 'print of f"[{json_path of ["{\"a\": 1}", "b"]}]"'
run "SM45 strict: JSON null still renders empty"        1 0 "[]" 'print of f"[{json_path of ["{\"a\": null}", "a"]}]"'
run "SM46 strict: valid nested path still resolves"     1 0 "x"  'print of (json_path of ["{\"a\": [1, {\"b\": \"x\"}]}", "a.1.b"])'

# --- #971 NaN-collapse: the reachable NaN sources raise under strict ------------
# Enumerated on the tree (the VM's own + - * / % cannot reach NaN from finite
# operands — 0/0 and x%0 raise first, and no operand can hold an inf): `pow`
# of a negative base with a fractional exponent, `num of "nan"` (strtod),
# `f64_from_bytes` of a NaN bit pattern, `matmul`'s inf-inf accumulation (list
# and buffer paths), `tensor_load` of a file carrying NaN bytes, and the
# elementwise `divide` by zero (pre-collapsed to 0 where `/` raises). Default
# collapses to 0 + math_flags.invalid exactly as before (SM47-SM49 pin it).
run "SM47 default pow(-8, 0.5) still 0"            unset 0 "0"  'print of (pow of [0 - 8, 0.5])'
run "SM48 default num(\"nan\") still 0 + invalid"  unset 0 "0 1" \
'local v is num of "nan"
print of f"{v} {(math_flags of null).invalid}"'
run "SM49a default matmul(inf-inf) LIST path still collapses to 0 + invalid" unset 0 "[0] 1" \
'local r is matmul of [[[1e200, 1e200]], [[1e200], [0 - 1e200]]]
print of f"{r} {(math_flags of null).invalid}"'
# The BUFFER path is deliberately NOT collapsed with the flag off. The kernel
# writes into the result buffer raw, so the NaN stays there, and a raw NaN in
# a buffer reads back as `null` (its bit pattern is a NaN-boxed slot tag,
# 0xFFF8... == SLOT_NULL_BITS) with math_flags.invalid still 0. That is what
# v0.43.0 does, and this change's contract is that the flag-off path is
# byte-identical to it: an earlier draft collapsed it to 0 here and had to
# carry a waiver in tools/strict_differential.sh to say so. The `null` read
# is a real defect and is recorded in ROADMAP.md as its own change; SM49b
# pins the CURRENT answer so that change cannot happen by accident.
run "SM49b default matmul(inf-inf) BUFFER path is byte-identical to v0.43.0" unset 0 "null 0" \
'local m1 is buffer of [1, 2]
m1[0] is 1e200
m1[1] is 1e200
local m2 is buffer of [2, 1]
m2[0] is 1e200
m2[1] is 0 - 1e200
local r is matmul of [m1, m2]
print of f"{r[0]} {(math_flags of null).invalid}"'
run "SM50 strict pow(-8, 0.5) raises, named"       1 1 "pow: result is not a number"     'print of (pow of [0 - 8, 0.5])'
run "SM51 strict elementwise pow raises"           1 1 "pow: result is not a number"     'print of (pow of [[0 - 8, 4], 0.5])'
run "SM52 strict num(\"nan\") raises, named"       1 1 "num: result is not a number"     'print of (num of "nan")'
run "SM53 strict f64_from_bytes(NaN bits) raises"  1 1 "f64_from_bytes: result is not a number" \
    'print of (f64_from_bytes of ([127, 248, 0, 0, 0, 0, 0, 0]))'
run "SM54 strict matmul list inf-inf raises"       1 1 "matmul: result is not a number" \
    'print of (matmul of [[[1e200, 1e200]], [[1e200], [0 - 1e200]]])'
run "SM55 strict matmul buffer inf-inf raises"     1 1 "matmul: result is not a number" \
'local m1 is buffer of [1, 2]
m1[0] is 1e200
m1[1] is 1e200
local m2 is buffer of [2, 1]
m2[0] is 1e200
m2[1] is 0 - 1e200
local r is matmul of [m1, m2]
print of (r[0])'
run "SM56 strict divide-by-zero (elementwise) raises" 1 1 "divide: division by zero" 'print of (divide of [[1], [0]])'
run "SM57 strict NaN raise is catchable as value"  1 0 "caught value" \
'try:
    x is pow of [0 - 8, 0.5]
catch e:
    print of f"caught {e.kind}"'
run "SM58 strict: num(\"inf\") still saturates (overflow, not NaN)" 1 0 "1e+308" 'print of (num of "inf")'
run "SM59 strict: pow with an integer exponent is defined"      1 0 "-8"     'print of (pow of [0 - 2, 3])'
run "SM60 strict: tensor_load of NaN bytes raises, named" 1 1 "tensor_load: result is not a number" \
'write_bytes of ["/tmp/eigs_strict_nan_$$.tensor", [1, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 248, 127, 0, 0, 0, 0, 0, 0, 4, 64]]
print of (tensor_load of "/tmp/eigs_strict_nan_$$.tensor")'
rm -f "/tmp/eigs_strict_nan_$$.tensor"
# The interpreter and the JIT must agree: the JIT bails to the interpreter on
# any non-finite result, so the raise comes from the same num_guard either way.
run_jitoff "SM61 strict pow raises with the JIT off too" "pow: result is not a number" \
'print of (pow of [0 - 8, 0.5])'

# --- #971 Phase D: the -1 / falsy sentinel families (#1008) and the --sweep list
# The documented sentinel for a valid-but-absent input is pinned in BOTH modes;
# only a wrong-typed argument raises.
run "SM62 strict: index_of miss is still -1"            1 0 "-1" 'print of (index_of of ["abc", "z"])'
run "SM63 strict: file_exists of an absent path is 0"   1 0 "0"  'print of (file_exists of "/nonexistent/eigs_971_probe")'
run "SM64 strict: is_dir of an absent path is 0"        1 0 "0"  'print of (is_dir of "/nonexistent/eigs_971_probe")'
run "SM65 strict: read_text of an absent path is empty" 1 0 "[]" 'print of f"[{read_text of "/nonexistent/eigs_971_probe"}]"'
run "SM66 strict index_of(num, str) raises"             1 1 "index_of: expected"    'print of (index_of of [42, "x"])'
run "SM67 strict file_exists(num) raises"               1 1 "file_exists: expected" 'print of (file_exists of 42)'
# --sweep candidates converted in this pass (each was a wrong type reading as
# a plausible answer: `split of 42` -> [""], `buffer of "x"` -> an empty
# buffer, `channel_closed of 42` -> 1 "closed", `f64_to_bytes of "x"` -> the
# bytes of 0.0, `random_int of "x"` -> 0, `json_build of {..}` -> "{}").
run "SM68 default split(num) still [\"\"]"              unset 0 '[""]' 'print of (split of 42)'
run "SM69 strict split(num) raises"                     1 1 "split: expected"       'print of (split of 42)'
run "SM70 strict split with a non-string delimiter raises" 1 1 "split: expected a string delimiter" 'print of (split of ["a b", 42])'
run "SM71 strict scan_ints(dict) raises"                1 1 "scan_ints: expected"   'print of (scan_ints of ({"k": 1}))'
run "SM72 strict buffer(str) raises"                    1 1 "buffer: expected"      'print of (buffer of "x")'
run "SM73 strict channel_closed(num) raises"            1 1 "channel_closed: expected" 'print of (channel_closed of 42)'
run "SM74 strict: unknown channel is still closed (1)"  1 0 "1"  'print of (channel_closed of ({"_channel_id": 99999}))'
run "SM75 strict f64_to_bytes(str) raises"              1 1 "f64_to_bytes: expected" 'print of (f64_to_bytes of "x")'
run "SM76 strict random_int(bad bounds) raises"         1 1 "random_int: expected" 'print of (random_int of ["a", 3])'
run "SM77 strict json_build(dict) raises"               1 1 "json_build: expected" 'print of (json_build of ({"a": 1}))'
run "SM78 strict: json_build of null is still {}"       1 0 "{}" 'print of (json_build of null)'
run "SM79 strict sort(dict) raises"                     1 1 "sort: expected a list" 'print of (sort of ({"a": 1}))'
run "SM80 strict token_name(str) raises"                1 1 "token_name: expected" 'print of (token_name of "x")'
run "SM81 strict: token_name of an unknown id is still ?" 1 0 "?" 'print of (token_name of 9999)'
run "SM82 strict tokenize_ids(num) raises"              1 1 "tokenize_ids: expected" 'print of (tokenize_ids of 42)'
run "SM83 strict random_hex(str) raises"                1 1 "random_hex: expected" 'print of (random_hex of "x")'
run "SM84 strict: random_hex of 0 is still empty"       1 0 "[]" 'print of f"[{random_hex of 0}]"'

# SM85-SM88 (#971 round 2): scan_ints had a row (SM71); its two siblings had
# none, so both leaked with no coverage at all. All three guards sit above the
# make_list they used to follow, and these rows are the leak-visible ones (the
# raise itself already exits 1, so only `leak_clean` can see a regression).
run "SM85 strict scan_tokens(num) raises"               1 1 "scan_tokens: expected"     'print of (scan_tokens of 42)'
run "SM86 strict scan_int_tokens(num) raises"           1 1 "scan_int_tokens: expected" 'print of (scan_int_tokens of 42)'
# Flag-off pins: the wrong type still reads as "no tokens" -> an empty list.
run "SM87 default scan_tokens(num) is still []"     unset 0 "[]" 'print of f"[{scan_tokens of 42}]"'
run "SM88 default scan_int_tokens(num) is still []" unset 0 "[]" 'print of f"[{scan_int_tokens of 42}]"'

echo "STRICT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
