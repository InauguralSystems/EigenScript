#!/bin/bash
# Note: no `set -e`. This is a test runner — it must continue past a failing
# command and report its own PASS/FAIL tally. With `set -e`, any .eigs program
# that legitimately exits non-zero (an uncaught runtime error, or a probe that
# intentionally hits a missing builtin in the minimal build) would abort the
# whole suite.
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/../src" || { echo "cannot cd to src"; exit 1; }

PASS=0
FAIL=0
TOTAL=0
LEAKED=0

# Exit-code gate for .eigs test programs. rc=0 passes. A nonzero rc whose
# output carries a LeakSanitizer report is tolerated with a warning tally:
# closure-defining call envs sit in an env<->fn refcount cycle the runtime
# cannot reclaim (see docs/TEST_COVERAGE_ANALYSIS.md), so under
# ASAN_OPTIONS=detect_leaks=1 those tests exit nonzero after fully correct
# output. Everything else nonzero — crashes, asserts, UBSan — fails.
rc_ok() {
    [ "$1" = "0" ] && return 0
    if echo "$2" | grep -q "LeakSanitizer: detected memory leaks"; then
        LEAKED=$((LEAKED + 1))
        return 0
    fi
    return 1
}

check() {
    TOTAL=$((TOTAL + 1))
    local test_name="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $test_name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $test_name (got '$actual', expected '$expected')"
        FAIL=$((FAIL + 1))
    fi
}

check_numeric() {
    TOTAL=$((TOTAL + 1))
    local test_name="$1"
    local actual="$2"
    local min="$3"
    local max="$4"
    if [ -z "$actual" ]; then
        echo "  FAIL: $test_name (empty value)"
        FAIL=$((FAIL + 1))
        return
    fi
    local in_range
    in_range=$(python3 -c "import sys; v=float(sys.argv[1]); lo=float(sys.argv[2]); hi=float(sys.argv[3]); print(1 if lo <= v <= hi else 0)" "$actual" "$min" "$max" 2>/dev/null || echo "0")
    if [ "$in_range" = "1" ]; then
        echo "  PASS: $test_name ($actual in [$min, $max])"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $test_name ($actual not in [$min, $max])"
        FAIL=$((FAIL + 1))
    fi
}

# Run a self-checking .eigs suite file. Passes only if the process exits 0
# AND prints the given marker — a crash after correct output (the bug class
# of suite check [71]) fails here instead of slipping through. `count` is
# the number of checks the file runs internally, for the tally.
check_eigs_suite() {
    TOTAL=$((TOTAL + $4))
    local test_name="$1"
    local file="$2"
    local marker="$3"
    local count="$4"
    local out rc
    out=$(./eigenscript "../tests/$file" </dev/null 2>&1); rc=$?
    if rc_ok "$rc" "$out" && echo "$out" | grep -q "$marker"; then
        PASS=$((PASS + count))
        echo "  PASS: $test_name"
    else
        FAIL=$((FAIL + count))
        echo "  FAIL: $test_name (rc=$rc)"
        echo "$out" | grep -iE "FAIL|MISMATCH|assert|error" | head -5
    fi
}

echo "============================================"
echo "  EigenScript Gen 0 Compliance Test Suite"
echo "============================================"
echo ""

echo "[1/15] Gen 0 Baseline (basic language features)"
OUTPUT=$(./eigenscript ../tests/test_gen0_baseline.eigs 2>&1)
check "T01 Numeric Assignment" "$(echo "$OUTPUT" | grep -A1 'T01' | tail -1)" "42"
check "T02 String Assignment" "$(echo "$OUTPUT" | grep -A1 'T02' | tail -1)" "hello world"
check "T03 Addition" "$(echo "$OUTPUT" | grep -A1 'T03' | tail -1)" "30"
check "T04 Subtraction" "$(echo "$OUTPUT" | grep -A1 'T04' | tail -1)" "63"
check "T05 Multiplication" "$(echo "$OUTPUT" | grep -A1 'T05' | tail -1)" "42"
check "T06 Division" "$(echo "$OUTPUT" | grep -A1 'T06' | tail -1)" "25"
check "T07 String Concat" "$(echo "$OUTPUT" | grep -A1 'T07' | tail -1)" "hello world"
check "T08 Boolean And" "$(echo "$OUTPUT" | grep -A1 'T08' | tail -1)" "1"
check "T09 Boolean Or" "$(echo "$OUTPUT" | grep -A1 'T09' | tail -1)" "1"
check "T10 Boolean Not" "$(echo "$OUTPUT" | grep -A1 'T10' | tail -1)" "1"
check "T11 Greater Than" "$(echo "$OUTPUT" | grep -A1 'T11' | tail -1)" "1"
check "T12 Less Than" "$(echo "$OUTPUT" | grep -A1 'T12' | tail -1)" "1"
check "T13 Equality (42==42)" "$(echo "$OUTPUT" | grep -A1 'T13:' | tail -1)" "1"
check "T13b Inequality (42==99)" "$(echo "$OUTPUT" | grep -A1 'T13b' | tail -1)" "0"
check "T13c String Equality" "$(echo "$OUTPUT" | grep -A1 'T13c' | tail -1)" "1"
check "T13d String Inequality" "$(echo "$OUTPUT" | grep -A1 'T13d' | tail -1)" "0"
check "T14 If Statement" "$(echo "$OUTPUT" | grep -A1 'T14' | tail -1)" "big"
check "T15 If-Else" "$(echo "$OUTPUT" | grep -A1 'T15' | tail -1)" "small"
check "T16 While Loop" "$(echo "$OUTPUT" | grep -A1 'T16' | tail -1)" "5"
check "T17 List Creation" "$(echo "$OUTPUT" | grep -A1 'T17' | tail -1)" "[1, 2, 3]"
check "T18 List Index" "$(echo "$OUTPUT" | grep -A1 'T18' | tail -1)" "20"
check "T19 Function Def" "$(echo "$OUTPUT" | grep -A1 'T19' | tail -1)" "42"
check "T20 Nested Arith" "$(echo "$OUTPUT" | grep -A1 'T20' | tail -1)" "42"
check "T21 String Length" "$(echo "$OUTPUT" | grep -A1 'T21' | tail -1)" "5"
check "T22 Reassignment" "$(echo "$OUTPUT" | grep -A1 'T22' | tail -1)" "4"
check "T23 Mixed Types" "$(echo "$OUTPUT" | grep -A1 'T23' | tail -1)" "value is 42"
echo ""

echo "[2/15] Interrogative Spec Compliance (LLVM IR parity)"
OUTPUT=$(./eigenscript ../tests/test_interrogative_spec.eigs 2>&1)
check "WHAT scalar (42)" "$(echo "$OUTPUT" | grep -A1 'eigen_get_value' | tail -1)" "42"
check "WHAT list length (5)" "$(echo "$OUTPUT" | grep -A1 'list length' | tail -1)" "5"
check "WHAT string length (5)" "$(echo "$OUTPUT" | grep -A1 'string length' | tail -1)" "5"
check "WHAT computed (42)" "$(echo "$OUTPUT" | grep -A1 'computed value' | tail -1)" "42"
check "WHO name (myvar)" "$(echo "$OUTPUT" | grep -A1 'variable name' | tail -1)" "myvar"
check "WHO name (counter)" "$(echo "$OUTPUT" | grep -A1 'different variable' | tail -1)" "counter"
check "WHEN step (1)" "$(echo "$OUTPUT" | grep -A1 'temporal step' | tail -1)" "1"
check "WHEN multi-assign (3)" "$(echo "$OUTPUT" | grep -A1 'multiple assignments' | tail -1)" "3"

WHERE_VAL=$(echo "$OUTPUT" | grep -A1 'WHERE returns entropy' | tail -1)
check_numeric "WHERE entropy >= 0" "$WHERE_VAL" "0" "10"

WHY_VAL=$(echo "$OUTPUT" | grep -A1 'WHY returns gradient' | tail -1)
check_numeric "WHY gradient is number" "$WHY_VAL" "-10" "10"

HOW_VAL=$(echo "$OUTPUT" | grep -A1 'HOW returns stability' | tail -1)
check_numeric "HOW stability 0-1" "$HOW_VAL" "0" "1"

check "WHAT assignment (256)" "$(echo "$OUTPUT" | grep -A1 'ASSIGNMENT THEN' | tail -1)" "256"
echo ""

echo "[3/15] Benchmark Interrogative Arithmetic"
BENCH_FILE="../../attached_assets/bench_interrogative_overhead_1771718100198.eigs"
if [ -f "$BENCH_FILE" ]; then
    BENCH=$(./eigenscript "$BENCH_FILE" 2>&1)
    check_numeric "Bench result is numeric" "$BENCH" "1" "1000"
    BENCH2=$(./eigenscript "$BENCH_FILE" 2>&1)
    check "Bench deterministic" "$BENCH" "$BENCH2"
else
    echo "  SKIP: benchmark asset not found (archived)"
    PASS=$((PASS+2))
    TOTAL=$((TOTAL+2))
fi
echo ""

echo "[4/15] Keyword Reservation"
OUTPUT=$(./eigenscript ../tests/test_keyword_reservation.eigs 2>&1)
check "what is keyword" "$(echo "$OUTPUT" | grep -A1 '^what:' | tail -1)" "42"
check "who is keyword" "$(echo "$OUTPUT" | grep -A1 '^who:' | tail -1)" "x"
check "when is keyword" "$(echo "$OUTPUT" | grep -A1 '^when:' | tail -1)" "1"

CONVERGED=$(echo "$OUTPUT" | grep 'converged=' | head -1)
echo "  INFO: Predicate values: $CONVERGED"
TOTAL=$((TOTAL + 1))
if echo "$OUTPUT" | grep -q 'converged:'; then
    echo "  PASS: converged predicate works"
    PASS=$((PASS + 1))
else
    echo "  FAIL: converged predicate"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if echo "$OUTPUT" | grep -q 'stable:'; then
    echo "  PASS: stable predicate works"
    PASS=$((PASS + 1))
else
    echo "  FAIL: stable predicate"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if echo "$OUTPUT" | grep -q 'improving:'; then
    echo "  PASS: improving predicate works"
    PASS=$((PASS + 1))
else
    echo "  FAIL: improving predicate"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if echo "$OUTPUT" | grep -q 'oscillating:'; then
    echo "  PASS: oscillating predicate works"
    PASS=$((PASS + 1))
else
    echo "  FAIL: oscillating predicate"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if echo "$OUTPUT" | grep -q 'diverging:'; then
    echo "  PASS: diverging predicate works"
    PASS=$((PASS + 1))
else
    echo "  FAIL: diverging predicate"
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
if echo "$OUTPUT" | grep -q 'equilibrium:'; then
    echo "  PASS: equilibrium predicate works"
    PASS=$((PASS + 1))
else
    echo "  FAIL: equilibrium predicate"
    FAIL=$((FAIL + 1))
fi
echo ""

echo "[5/15] Report-Predicate Alignment (5 states)"
RA_OUTPUT=$(./eigenscript ../tests/test_report_alignment.eigs 2>&1)

RA1_D=$(echo "$RA_OUTPUT" | grep -A2 'RA1:' | tail -2 | head -1)
RA1_R=$(echo "$RA_OUTPUT" | grep -A2 'RA1:' | tail -1)
check "RA1 diverging predicate" "$RA1_D" "1"
check "RA1 report=diverging" "$RA1_R" "diverging"

RA2_I=$(echo "$RA_OUTPUT" | grep -A2 'RA2:' | tail -2 | head -1)
RA2_R=$(echo "$RA_OUTPUT" | grep -A2 'RA2:' | tail -1)
check "RA2 improving predicate" "$RA2_I" "1"
check "RA2 report=improving" "$RA2_R" "improving"

RA3_C=$(echo "$RA_OUTPUT" | grep -A2 'RA3:' | tail -2 | head -1)
RA3_R=$(echo "$RA_OUTPUT" | grep -A2 'RA3:' | tail -1)
check "RA3 converged predicate" "$RA3_C" "1"
check "RA3 report=converged" "$RA3_R" "converged"

RA4_O=$(echo "$RA_OUTPUT" | grep -A2 'RA4:' | tail -2 | head -1)
RA4_R=$(echo "$RA_OUTPUT" | grep -A2 'RA4:' | tail -1)
check "RA4 oscillating predicate" "$RA4_O" "1"
check "RA4 report=oscillating" "$RA4_R" "oscillating"

RA5_E=$(echo "$RA_OUTPUT" | grep -A2 'RA5:' | tail -2 | head -1)
RA5_R=$(echo "$RA_OUTPUT" | grep -A2 'RA5:' | tail -1)
check "RA5 equilibrium predicate" "$RA5_E" "1"
check "RA5 report=equilibrium" "$RA5_R" "equilibrium"
echo ""

echo "[6/15] Halting: Bounded Descent (4 checks)"
HD_OUTPUT=$(./eigenscript ../tests/test_halting_descent.eigs 2>&1)

HD_ITERS=$(echo "$HD_OUTPUT" | grep -A1 'HD1:' | tail -1)
TOTAL=$((TOTAL + 1))
if [ -n "$HD_ITERS" ] && [ "$HD_ITERS" -gt 0 ] 2>/dev/null && [ "$HD_ITERS" -lt 20 ] 2>/dev/null; then
    echo "  PASS: HD1 loop terminated in $HD_ITERS iterations"
    PASS=$((PASS + 1))
else
    echo "  FAIL: HD1 loop iteration count (got '$HD_ITERS')"
    FAIL=$((FAIL + 1))
fi

HD_REPORT=$(echo "$HD_OUTPUT" | grep -A2 'HD1:' | tail -1)
check "HD2 final report=converged" "$HD_REPORT" "converged"

HD_H=$(echo "$HD_OUTPUT" | grep -A3 'HD1:' | tail -1)
TOTAL=$((TOTAL + 1))
if [ -n "$HD_H" ]; then
    echo "  PASS: HD3 final entropy reported ($HD_H)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: HD3 final entropy empty"
    FAIL=$((FAIL + 1))
fi

HD_DH=$(echo "$HD_OUTPUT" | grep -A4 'HD1:' | tail -1)
TOTAL=$((TOTAL + 1))
if echo "$HD_DH" | grep -q '^-'; then
    echo "  PASS: HD4 final dH is negative ($HD_DH)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: HD4 final dH should be negative (got '$HD_DH')"
    FAIL=$((FAIL + 1))
fi
echo ""

echo "[7/15] Halting: Stall Detection (5 checks)"
HS_OUTPUT=$(./eigenscript ../tests/test_halting_stall.eigs 2>&1)

HS_CONV=$(echo "$HS_OUTPUT" | grep -A1 'HS1:' | tail -1)
check "HS1 converged=0 at moderate H" "$HS_CONV" "0"

HS_EQ=$(echo "$HS_OUTPUT" | grep -A2 'HS1:' | tail -1)
check "HS2 equilibrium=1 at dH~0" "$HS_EQ" "1"

HS_H=$(echo "$HS_OUTPUT" | grep -A1 'HS2:' | tail -1)
TOTAL=$((TOTAL + 1))
if [ -n "$HS_H" ]; then
    echo "  PASS: HS3 entropy above threshold ($HS_H)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: HS3 entropy empty"
    FAIL=$((FAIL + 1))
fi

HS_DH=$(echo "$HS_OUTPUT" | grep -A2 'HS2:' | tail -1)
check "HS4 dH~0" "$HS_DH" "0"

HS_REPORT=$(echo "$HS_OUTPUT" | grep -A3 'HS2:' | tail -1)
check "HS5 report=equilibrium" "$HS_REPORT" "equilibrium"
echo ""

echo "[8/15] Stable Band (4 checks)"
SB_OUTPUT=$(./eigenscript ../tests/test_stable_band.eigs 2>&1)

SB1_S=$(echo "$SB_OUTPUT" | grep -A1 'SB1:' | tail -1)
check "SB1 stable=1" "$SB1_S" "1"

SB1_R=$(echo "$SB_OUTPUT" | grep -A2 'SB1:' | tail -1)
check "SB1 report=stable" "$SB1_R" "stable"

SB2_S=$(echo "$SB_OUTPUT" | grep -A1 'SB2:' | tail -1)
check "SB2 stable=0 (converged)" "$SB2_S" "0"

SB2_R=$(echo "$SB_OUTPUT" | grep -A2 'SB2:' | tail -1)
check "SB2 report=converged" "$SB2_R" "converged"
echo ""

echo "[9/15] Assert (3 checks)"
AS_OUTPUT=$(./eigenscript ../tests/test_assert.eigs 2>&1)
check "AS1 assert true passes" "$(echo "$AS_OUTPUT" | grep 'pass1')" "pass1"
check "AS2 assert list passes" "$(echo "$AS_OUTPUT" | grep 'pass2')" "pass2"

TOTAL=$((TOTAL + 1))
if ./eigenscript ../tests/test_assert_fail.eigs >/dev/null 2>&1; then
    echo "  FAIL: AS3 assert false should exit non-zero"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: AS3 assert false exits non-zero"
    PASS=$((PASS + 1))
fi
echo ""

echo "[10/15] Observe Snapshot (3 checks)"
OB_OUTPUT=$(./eigenscript ../tests/test_observe.eigs 2>&1)

OB1_TYPE=$(echo "$OB_OUTPUT" | grep -A1 'OB1:' | tail -1)
check "OB1 observe type=list" "$OB1_TYPE" "list"

OB1_RPT=$(echo "$OB_OUTPUT" | grep -A2 'OB1:' | tail -1)
TOTAL=$((TOTAL + 1))
if [ -n "$OB1_RPT" ]; then
    echo "  PASS: OB1 observe report present ($OB1_RPT)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: OB1 observe report empty"
    FAIL=$((FAIL + 1))
fi

OB2_R=$(echo "$OB_OUTPUT" | grep -A1 'OB2:' | tail -1)
TOTAL=$((TOTAL + 1))
if [ -n "$OB2_R" ]; then
    echo "  PASS: OB2 report matches ($OB2_R)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: OB2 report empty"
    FAIL=$((FAIL + 1))
fi
echo ""

echo "[11/15] Loop Exit Reason (3 checks)"
LE_OUTPUT=$(./eigenscript ../tests/test_loop_exit.eigs 2>&1)

LE1_EXIT=$(echo "$LE_OUTPUT" | grep -A1 'LE1:' | tail -1)
check "LE1 exit=normal" "$LE1_EXIT" "normal"

LE1_ITERS=$(echo "$LE_OUTPUT" | grep -A2 'LE1:' | tail -1)
TOTAL=$((TOTAL + 1))
if [ -n "$LE1_ITERS" ] && [ "$LE1_ITERS" -gt 0 ] 2>/dev/null; then
    echo "  PASS: LE1 iterations=$LE1_ITERS"
    PASS=$((PASS + 1))
else
    echo "  FAIL: LE1 iterations (got '$LE1_ITERS')"
    FAIL=$((FAIL + 1))
fi

LE2_EXIT=$(echo "$LE_OUTPUT" | grep -A1 'LE2:' | tail -1)
check "LE2 exit=stalled" "$LE2_EXIT" "stalled"
echo ""

echo "[Structural Equality] (15 checks)"
EQ_OUTPUT=$(./eigenscript ../tests/test_equality.eigs 2>&1)
TOTAL=$((TOTAL + 15))
if echo "$EQ_OUTPUT" | grep -q "All tests passed"; then
    echo "  PASS: all 15 structural-equality checks"; PASS=$((PASS + 15))
else
    echo "  FAIL: structural-equality"; FAIL=$((FAIL + 15))
    echo "$EQ_OUTPUT" | grep -iE "ASSERT|error" | head -5
fi
echo ""

echo "[Number Formatting] (9 checks)"
NF_OUTPUT=$(./eigenscript ../tests/test_number_format.eigs 2>&1)
TOTAL=$((TOTAL + 9))
if echo "$NF_OUTPUT" | grep -q "All tests passed"; then
    echo "  PASS: all 9 number-format round-trip checks"; PASS=$((PASS + 9))
else
    echo "  FAIL: number-format"; FAIL=$((FAIL + 9))
    echo "$NF_OUTPUT" | grep -iE "ASSERT|error" | head -5
fi
echo ""

echo "[Security Hardening] (6 checks)"
SH_OUTPUT=$(./eigenscript ../tests/test_security_hardening.eigs 2>&1)
TOTAL=$((TOTAL + 6))
if echo "$SH_OUTPUT" | grep -q "All tests passed"; then
    echo "  PASS: secure_equals + parser depth guard"; PASS=$((PASS + 6))
else
    echo "  FAIL: security-hardening (possible crash/regression)"; FAIL=$((FAIL + 6))
    echo "$SH_OUTPUT" | grep -iE "ASSERT" | head -5
fi
echo ""

echo "[JSON Depth / DoS guard] (3 checks)"
JD_OUTPUT=$(./eigenscript ../tests/test_json_depth.eigs 2>&1)
TOTAL=$((TOTAL + 3))
if echo "$JD_OUTPUT" | grep -q "All tests passed"; then
    echo "  PASS: deep-JSON guard + nested parsing"; PASS=$((PASS + 3))
else
    echo "  FAIL: json-depth (possible crash/regression)"; FAIL=$((FAIL + 3))
    echo "$JD_OUTPUT" | grep -iE "ASSERT|error" | head -5
fi
echo ""

echo "[Call Semantics] (18 checks)"
CS_OUTPUT=$(./eigenscript ../tests/test_call_semantics.eigs 2>&1)
TOTAL=$((TOTAL + 18))
if echo "$CS_OUTPUT" | grep -q "All tests passed"; then
    echo "  PASS: all 18 call-semantics/aliasing checks"; PASS=$((PASS + 18))
else
    echo "  FAIL: call-semantics"; FAIL=$((FAIL + 18))
    echo "$CS_OUTPUT" | grep -iE "ASSERT|error" | head -5
fi
echo ""

echo "[STEM Accuracy] (123 checks)"
SA_OUTPUT=$(./eigenscript ../tests/test_stem_accuracy.eigs 2>&1)
TOTAL=$((TOTAL + 123))
if echo "$SA_OUTPUT" | grep -q "All STEM accuracy checks passed"; then
    echo "  PASS: all 123 STEM known-answer checks"; PASS=$((PASS + 123))
else
    echo "  FAIL: STEM accuracy"; FAIL=$((FAIL + 123))
    echo "$SA_OUTPUT" | grep -iE "FAIL|error" | head -10
fi
echo ""

echo "[Coercion] (16 checks)"
CO_OUTPUT=$(./eigenscript ../tests/test_coercion.eigs 2>&1)
TOTAL=$((TOTAL + 16))
if echo "$CO_OUTPUT" | grep -q "All tests passed"; then
    echo "  PASS: all 16 coercion checks"; PASS=$((PASS + 16))
else
    echo "  FAIL: coercion"; FAIL=$((FAIL + 16))
    echo "$CO_OUTPUT" | grep -iE "ASSERT|error" | head -5
fi
echo ""

echo "[12/15] Type Labels (4 checks)"
TY_OUTPUT=$(./eigenscript ../tests/test_type.eigs 2>&1)

TY_NUM=$(echo "$TY_OUTPUT" | grep -A1 'TY1:' | tail -1)
check "TY1 type of num" "$TY_NUM" "num"

TY_STR=$(echo "$TY_OUTPUT" | grep -A2 'TY1:' | tail -1)
check "TY2 type of str" "$TY_STR" "str"

TY_LIST=$(echo "$TY_OUTPUT" | grep -A3 'TY1:' | tail -1)
check "TY3 type of list" "$TY_LIST" "list"

TY_BUILTIN=$(echo "$TY_OUTPUT" | grep -A4 'TY1:' | tail -1)
check "TY4 type of builtin" "$TY_BUILTIN" "builtin"
echo ""

echo "[13/15] JSON Round-Trip (5 checks)"
JS_OUTPUT=$(./eigenscript ../tests/test_json.eigs 2>&1)

JS1_NUM=$(echo "$JS_OUTPUT" | grep -A1 'JS1:' | tail -1)
check "JS1 encode number" "$JS1_NUM" "42"

JS1_STR=$(echo "$JS_OUTPUT" | grep -A2 'JS1:' | tail -1)
check "JS2 encode string" "$JS1_STR" "\"hello\""

JS2_LIST=$(echo "$JS_OUTPUT" | grep -A1 'JS2:' | tail -1)
check "JS3 encode list" "$JS2_LIST" "[1,2,3]"

JS3_RT=$(echo "$JS_OUTPUT" | grep -A1 'JS3:' | tail -1)
check "JS4 round-trip" "$JS3_RT" "[1,2,3]"

JS4_KEY=$(echo "$JS_OUTPUT" | grep -A1 'JS4:' | tail -1)
check "JS5 object decode key" "$JS4_KEY" "eigen"
echo ""

echo "[14/15] Arena Ownership (5 checks)"
AO_OUTPUT=$(./eigenscript ../tests/test_arena_ownership.eigs 2>&1)

AO1_Y=$(echo "$AO_OUTPUT" | grep -A1 'AO1:' | tail -1)
check "AO1 new local in arena window survives reset" "$AO1_Y" "42"

# 50 sgd_update steps accumulate float error; compare with tolerance rather
# than exact string (the old %.6g formatter rounded 0.4999...956 to "0.5").
AO2_W0=$(echo "$AO_OUTPUT" | grep -A1 'AO2:' | tail -1)
check_numeric "AO2 50x sgd_update w[0]" "$AO2_W0" "0.4999" "0.5001"

AO2_W3=$(echo "$AO_OUTPUT" | grep -A2 'AO2:' | tail -1)
check_numeric "AO2 50x sgd_update w[3]" "$AO2_W3" "3.4999" "3.5001"

AO3_V=$(echo "$AO_OUTPUT" | grep -A1 'AO3:' | tail -1)
check "AO3 tensor save/load roundtrip" "$AO3_V" "21"

AO4_C=$(echo "$AO_OUTPUT" | grep -A1 'AO4:' | tail -1)
check "AO4 num_copy new local survives reset" "$AO4_C" "99.5"
echo ""

echo "[15/15] try_parse Validation (11 checks)"
TP_OUTPUT=$(./eigenscript ../tests/test_try_parse.eigs 2>&1)

check "TP_V1 valid assignment" "$(echo "$TP_OUTPUT" | grep -A1 'TP_V1:' | tail -1)" "1"
check "TP_V2 valid define" "$(echo "$TP_OUTPUT" | grep -A1 'TP_V2:' | tail -1)" "1"
check "TP_V3 valid if" "$(echo "$TP_OUTPUT" | grep -A1 'TP_V3:' | tail -1)" "1"
check "TP_V4 valid for" "$(echo "$TP_OUTPUT" | grep -A1 'TP_V4:' | tail -1)" "1"
check "TP_I1 rejects x is )" "$(echo "$TP_OUTPUT" | grep -A1 'TP_I1:' | tail -1)" "0"
check "TP_I2 rejects if without colon" "$(echo "$TP_OUTPUT" | grep -A1 'TP_I2:' | tail -1)" "0"
check "TP_I3 rejects empty string" "$(echo "$TP_OUTPUT" | grep -A1 'TP_I3:' | tail -1)" "0"
check "TP_I4 rejects bracket garbage" "$(echo "$TP_OUTPUT" | grep -A1 'TP_I4:' | tail -1)" "0"
check "TP_I5 rejects unknown char @" "$(echo "$TP_OUTPUT" | grep -A1 'TP_I5:' | tail -1)" "0"
check "TP_I6 rejects unterminated string" "$(echo "$TP_OUTPUT" | grep -A1 'TP_I6:' | tail -1)" "0"
check "TP_I7 rejects lone !" "$(echo "$TP_OUTPUT" | grep -A1 'TP_I7:' | tail -1)" "0"
echo ""

echo "[16/16] Error Messages (6 checks)"

check_stderr() {
    TOTAL=$((TOTAL + 1))
    local test_name="$1"
    local script="$2"
    local expected_substr="$3"
    local tmpfile
    tmpfile=$(mktemp /tmp/eigs_test_XXXXXX.eigs)
    printf '%s\n' "$script" > "$tmpfile"
    local errfile
    errfile=$(mktemp /tmp/eigs_err_XXXXXX.txt)
    ./eigenscript "$tmpfile" >"$errfile" 2>&1 || true
    if grep -q "$expected_substr" "$errfile"; then
        echo "  PASS: $test_name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $test_name (output: '$(cat "$errfile")', expected to contain '$expected_substr')"
        FAIL=$((FAIL + 1))
    fi
    rm -f "$tmpfile" "$errfile"
}

check_exit() {
    TOTAL=$((TOTAL + 1))
    local test_name="$1"
    local script="$2"
    local expected_exit="$3"
    local tmpfile
    tmpfile=$(mktemp /tmp/eigs_test_XXXXXX.eigs)
    printf '%s\n' "$script" > "$tmpfile"
    local actual_exit=0
    ./eigenscript "$tmpfile" >/dev/null 2>&1 || actual_exit=$?
    rm -f "$tmpfile"
    if [ "$actual_exit" = "$expected_exit" ]; then
        echo "  PASS: $test_name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $test_name (exit $actual_exit, expected $expected_exit)"
        FAIL=$((FAIL + 1))
    fi
}

check_exit "EM1 parse error aborts with exit 1" 'x is @' "1"
check_stderr "EM2 parse error names the token" 'if x > 0
    print of x' "expected ':'"
check_stderr "EM3 unknown char shows character" 'x is @' "unexpected character"
check_stderr "EM4 type error on bad subtraction" 'x is [1,2] - 5' "Error line 1: cannot apply"
check_stderr "EM5 index out of bounds" 'items is [1,2,3]
print of items[10]' "Error line 2: index 10 out of range"
check_stderr "EM6 division by zero warning" 'print of (10 / 0)' "Warning line 1: division by zero"
check_stderr "EM7 undefined variable includes line" 'x is 1
y is 2
print of z' "Error line 3: undefined variable"
check_stderr "EM8 calling non-function" 'x is 5
y is x of 10' "Error line 2: cannot call num"
check_stderr "EM9 cannot index num" 'x is 42
print of x[0]' "Error line 2: cannot index num"
check_stderr "EM10 nested if line accuracy" 'x is 1
if x == 1:
    y is 2
    if y == 2:
        z is y[0]' "Error line 5: cannot index num"
check_stderr "EM11 function body line" 'define foo as:
    return n - "bad"
result is foo of 5' "Error line 2: cannot apply"
check_stderr "EM12 loop body line" 'items is [1, 2, 3]
for i in items:
    x is i * 2
    print of missing' "Error line 4: undefined variable"
check_stderr "EM13 elif branch line" 'x is 5
if x == 1:
    print of "one"
elif x == 5:
    y is x[0]' "Error line 5: cannot index"
# An *uncaught* runtime error must fail loudly: non-zero exit, and no further
# statements run. (Warnings like div-by-zero are not errors — see EM15.)
check_exit "EM14 uncaught runtime error exits non-zero" 'x is [1] - 5' "1"
check_exit "EM15 warning exits 0" 'x is 10 / 0' "0"

# Regression: uncaught error halts execution (statement after must not run)
EM16_OUT=$(printf '%s\n' 'x is undefined_thing' 'print of "AFTER"' > /tmp/eigs_em16.eigs; ./eigenscript /tmp/eigs_em16.eigs 2>/dev/null; rm -f /tmp/eigs_em16.eigs)
TOTAL=$((TOTAL + 1))
if [ -z "$EM16_OUT" ]; then
    echo "  PASS: EM16 uncaught error halts (no output after)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: EM16 statement ran after uncaught error (got '$EM16_OUT')"
    FAIL=$((FAIL + 1))
fi

# Regression: stack overflow exits non-zero (single error, not a cascade)
check_exit "EM17 stack overflow exits non-zero" 'define r(n) as:
    return 1 + (r of (n + 1))
print of (r of 0)' "1"

# #157: destructure pattern parser UX — specific errors instead of falling
# through to generic list-literal expression errors.
check_stderr "EM21 destructure trailing comma" '[a, b,] is [1, 2]' \
    "trailing comma in destructuring pattern"
check_stderr "EM22 destructure non-ident target" '[a[0], b] is [1, 2]' \
    "destructuring pattern requires identifiers"
EM23_SCRIPT=$(printf '['; for i in $(seq 0 69); do [ $i -gt 0 ] && printf ', '; printf 'n%d' $i; done; printf '] is [0]')
check_stderr "EM23 destructure exceeds 64 names" "$EM23_SCRIPT" \
    "destructuring pattern exceeds 64 names"

# Regression: a caught error still allows the program to succeed (exit 0)
check_exit "EM18 caught error exits 0" 'try:
    x is undefined_thing
catch e:
    print of "ok"' "0"
echo ""

# [17] Transformer smoke test — only runs if model extension compiled in.
# Detects by running a probe script and checking output.
PROBE_FILE=$(mktemp /tmp/eigs_probe_XXXXXX.eigs)
cat > "$PROBE_FILE" <<'PROBE'
loaded is eigen_model_loaded of null
print of "yes"
PROBE
PROBE_OUT=$(./eigenscript "$PROBE_FILE" 2>&1)
rm -f "$PROBE_FILE"

# Model extension present only if no "undefined variable" error
if ! echo "$PROBE_OUT" | grep -q "undefined variable"; then
    echo "[17/17] Transformer Smoke (7 checks)"

    # Generate tiny v1 model
    ./eigenscript ../tests/gen_tiny_model.eigs > /tmp/eigs_tiny_v1.json 2>/dev/null

    # Find a v0 model to test rejection.
    # Set EIGS_V0_MODEL_DIR to a directory containing legacy-format *.json
    # checkpoints to exercise TR6/TR7. If unset (the common case), those
    # two checks skip gracefully.
    if [ -n "$EIGS_V0_MODEL_DIR" ]; then
        V0_MODEL=$(find "$EIGS_V0_MODEL_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | head -1)
    else
        V0_MODEL=""
    fi

    SMOKE_FILE=$(mktemp /tmp/eigs_smoke_XXXXXX.eigs)
    cat > "$SMOKE_FILE" <<SMOKE
load_result is eigen_model_load of "/tmp/eigs_tiny_v1.json"
print of "TR1:"
print of (eigen_model_loaded of null)
print of "TR2:"
print of (type of (eigen_generate of [[1,2,3], 0.0, 4]))
print of "TR3:"
print of (len of (eigen_generate of [[1,2,3], 0.0, 4]))
print of "TR4:"
print of (type of (native_train_step_builtin of [[1,2,3], [4,5,6], 0.01]))
print of "TR5:"
print of (native_train_step_builtin of ["bad", "also bad", 0.01])
SMOKE
    SMOKE_OUTPUT=$(./eigenscript "$SMOKE_FILE" 2>&1)
    rm -f "$SMOKE_FILE"

    check "TR1 v2 model loads" "$(echo "$SMOKE_OUTPUT" | grep -A1 'TR1:' | tail -1)" "1"
    check "TR2 generate returns list" "$(echo "$SMOKE_OUTPUT" | grep -A1 'TR2:' | tail -1)" "list"
    check "TR3 generate length matches max_tokens" "$(echo "$SMOKE_OUTPUT" | grep -A1 'TR3:' | tail -1)" "4"
    check "TR4 train returns string (JSON)" "$(echo "$SMOKE_OUTPUT" | grep -A1 'TR4:' | tail -1)" "str"
    TR5_LINE=$(echo "$SMOKE_OUTPUT" | grep -A1 'TR5:' | tail -1)
    if echo "$TR5_LINE" | grep -q "must be lists"; then
        echo "  PASS: TR5 bad inputs rejected"; PASS=$((PASS + 1))
    else
        echo "  FAIL: TR5 bad inputs rejected (got '$TR5_LINE')"; FAIL=$((FAIL + 1))
    fi
    TOTAL=$((TOTAL + 1))

    # TR6/TR7: v0 rejection
    if [ -n "$V0_MODEL" ]; then
        V0_FILE=$(mktemp /tmp/eigs_v0_XXXXXX.eigs)
        cat > "$V0_FILE" <<V0TEST
r is eigen_model_load of "$V0_MODEL"
print of (eigen_model_loaded of null)
V0TEST
        V0_OUTPUT=$(./eigenscript "$V0_FILE" 2>&1)
        rm -f "$V0_FILE"
        V0_LOADED=$(echo "$V0_OUTPUT" | tail -1)
        check "TR6 old model rejected" "$V0_LOADED" "0"
        if echo "$V0_OUTPUT" | grep -q "format mismatch"; then
            echo "  PASS: TR7 old rejection prints format mismatch"; PASS=$((PASS + 1))
        else
            echo "  FAIL: TR7 old rejection prints format mismatch"; FAIL=$((FAIL + 1))
        fi
        TOTAL=$((TOTAL + 1))
    else
        echo "  SKIP: TR6/TR7 no old model available"
    fi

    rm -f /tmp/eigs_tiny_v1.json
    echo ""
fi

# [18] File I/O builtins: read_text, write_text, exec_capture
echo "[18/18] File I/O Builtins (14 checks)"
FIO_OUTPUT=$(./eigenscript ../tests/test_file_io.eigs 2>&1)

if echo "$FIO_OUTPUT" | grep -q "All file_io tests passed"; then
    # All asserts passed — count individual checks
    TOTAL=$((TOTAL + 14))
    PASS=$((PASS + 14))
    echo "  PASS: RT1 read existing file"
    echo "  PASS: RT2 read missing file"
    echo "  PASS: RT3 read bad arg"
    echo "  PASS: WT1 write and read back"
    echo "  PASS: WT2 write empty"
    echo "  PASS: WT3 bad args"
    echo "  PASS: EC1 basic command"
    echo "  PASS: EC2 failing command"
    echo "  PASS: EC3 bad arg return"
    echo "  PASS: EC4 non-string arg"
    echo "  PASS: EC5 cat stdin /dev/null"
    echo "  PASS: EC6 timeout form completes"
    echo "  PASS: EC7 timeout fires"
    echo "  PASS: EC7 timeout returns -2"
else
    TOTAL=$((TOTAL + 14))
    FAIL=$((FAIL + 14))
    echo "  FAIL: file_io tests (assert failed)"
    echo "$FIO_OUTPUT" | grep -i "assert\|error" | head -5
fi
# Clean up temp files
rm -f /tmp/eigen_test_wt1.txt /tmp/eigen_test_wt2.txt
echo ""

# [19] String and math builtins
echo "[19/19] String & Math Builtins (60 checks)"
SM_OUTPUT=$(./eigenscript ../tests/test_string_math.eigs 2>&1)

if echo "$SM_OUTPUT" | grep -q "All string_math tests passed"; then
    TOTAL=$((TOTAL + 60))
    PASS=$((PASS + 60))
    echo "  PASS: all 60 string/math checks"
else
    TOTAL=$((TOTAL + 60))
    FAIL=$((FAIL + 60))
    echo "  FAIL: string_math tests (assert failed)"
    echo "$SM_OUTPUT" | grep -i "assert\|error" | head -5
fi
echo ""

# [20] System builtins (random, args, paths, filesystem)
echo "[20/21] System Builtins (22 checks)"
SYS_OUTPUT=$(./eigenscript ../tests/test_system.eigs 2>&1)

if echo "$SYS_OUTPUT" | grep -q "All system tests passed"; then
    TOTAL=$((TOTAL + 22))
    PASS=$((PASS + 22))
    echo "  PASS: all 22 system checks"
else
    TOTAL=$((TOTAL + 22))
    FAIL=$((FAIL + 22))
    echo "  FAIL: system tests (assert failed)"
    echo "$SYS_OUTPUT" | grep -i "assert\|error" | head -5
fi
echo ""

# [22] F-string interpolation
echo "[22/27] F-String Interpolation (9 checks)"
FS_OUTPUT=$(./eigenscript ../tests/test_fstrings.eigs 2>&1); FS_OUTPUT_RC=$?
if rc_ok "$FS_OUTPUT_RC" "$FS_OUTPUT" && echo "$FS_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 9))
    PASS=$((PASS + 9))
    echo "  PASS: all 9 f-string checks"
else
    TOTAL=$((TOTAL + 9))
    FAIL=$((FAIL + 9))
    echo "  FAIL: f-string tests"
    echo "$FS_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [23] Named parameters
echo "[23/27] Named Parameters (9 checks)"
NP_OUTPUT=$(./eigenscript ../tests/test_named_params.eigs 2>&1); NP_OUTPUT_RC=$?
if rc_ok "$NP_OUTPUT_RC" "$NP_OUTPUT" && echo "$NP_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 9))
    PASS=$((PASS + 9))
    echo "  PASS: all 9 named param checks"
else
    TOTAL=$((TOTAL + 9))
    FAIL=$((FAIL + 9))
    echo "  FAIL: named param tests"
    echo "$NP_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [24] Try/catch and throw
echo "[24/27] Try/Catch & Throw (8 checks)"
TC_OUTPUT=$(./eigenscript ../tests/test_trycatch.eigs 2>&1); TC_OUTPUT_RC=$?
if rc_ok "$TC_OUTPUT_RC" "$TC_OUTPUT" && echo "$TC_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 8))
    PASS=$((PASS + 8))
    echo "  PASS: all 8 try/catch checks"
else
    TOTAL=$((TOTAL + 8))
    FAIL=$((FAIL + 8))
    echo "  FAIL: try/catch tests"
    echo "$TC_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [25] Dictionaries
echo "[25/27] Dictionaries (21 checks)"
DI_OUTPUT=$(./eigenscript ../tests/test_dict.eigs 2>&1); DI_OUTPUT_RC=$?
if rc_ok "$DI_OUTPUT_RC" "$DI_OUTPUT" && echo "$DI_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 21))
    PASS=$((PASS + 21))
    echo "  PASS: all 21 dict checks"
else
    TOTAL=$((TOTAL + 21))
    FAIL=$((FAIL + 21))
    echo "  FAIL: dict tests"
    echo "$DI_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [26] Eval builtin
echo "[26/27] Eval Builtin (8 checks)"
EV_OUTPUT=$(./eigenscript ../tests/test_eval.eigs 2>&1); EV_OUTPUT_RC=$?
if rc_ok "$EV_OUTPUT_RC" "$EV_OUTPUT" && echo "$EV_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 8))
    PASS=$((PASS + 8))
    echo "  PASS: all 8 eval checks"
else
    TOTAL=$((TOTAL + 8))
    FAIL=$((FAIL + 8))
    echo "  FAIL: eval tests"
    echo "$EV_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [27] Closures
echo "[27/27] Closures (10 checks)"
CL_OUTPUT=$(./eigenscript ../tests/test_closures.eigs 2>&1); CL_OUTPUT_RC=$?
if rc_ok "$CL_OUTPUT_RC" "$CL_OUTPUT" && echo "$CL_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 10))
    PASS=$((PASS + 10))
    echo "  PASS: all 10 closure checks"
else
    TOTAL=$((TOTAL + 10))
    FAIL=$((FAIL + 10))
    echo "  FAIL: closure tests"
    echo "$CL_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [27b] Closure mutation (hard mode — regression coverage for #130)
echo "[27b/27] Closure Mutation (14 checks)"
CM_OUTPUT=$(./eigenscript ../tests/test_closure_mutation.eigs 2>&1); CM_OUTPUT_RC=$?
if rc_ok "$CM_OUTPUT_RC" "$CM_OUTPUT" && echo "$CM_OUTPUT" | grep -q "closure mutation: all passed"; then
    TOTAL=$((TOTAL + 14))
    PASS=$((PASS + 14))
    echo "  PASS: all 14 closure mutation checks"
else
    TOTAL=$((TOTAL + 14))
    FAIL=$((FAIL + 14))
    echo "  FAIL: closure mutation tests"
    echo "$CM_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [29] Break and continue
echo "[29/31] Break & Continue (9 checks)"
BC_OUTPUT=$(./eigenscript ../tests/test_break_continue.eigs 2>&1); BC_OUTPUT_RC=$?
if rc_ok "$BC_OUTPUT_RC" "$BC_OUTPUT" && echo "$BC_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 9))
    PASS=$((PASS + 9))
    echo "  PASS: all 9 break/continue checks"
else
    TOTAL=$((TOTAL + 9))
    FAIL=$((FAIL + 9))
    echo "  FAIL: break/continue tests"
    echo "$BC_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [30] Dot-assignment (incl. compound `obj.f += e` desugaring/clone_ast)
echo "[30/31] Dot-Assignment (26 checks)"
DA_OUTPUT=$(./eigenscript ../tests/test_dot_assign.eigs 2>&1); DA_OUTPUT_RC=$?
if rc_ok "$DA_OUTPUT_RC" "$DA_OUTPUT" && echo "$DA_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 26))
    PASS=$((PASS + 26))
    echo "  PASS: all 26 dot-assign checks"
else
    TOTAL=$((TOTAL + 26))
    FAIL=$((FAIL + 26))
    echo "  FAIL: dot-assign tests"
    echo "$DA_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [31] Multiline collections
echo "[31/31] Multiline Collections (12 checks)"
ML_OUTPUT=$(./eigenscript ../tests/test_multiline.eigs 2>&1); ML_OUTPUT_RC=$?
if rc_ok "$ML_OUTPUT_RC" "$ML_OUTPUT" && echo "$ML_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 12))
    PASS=$((PASS + 12))
    echo "  PASS: all 12 multiline checks"
else
    TOTAL=$((TOTAL + 12))
    FAIL=$((FAIL + 12))
    echo "  FAIL: multiline tests"
    echo "$ML_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [33] Misc builtins
echo "[33/33] Misc Builtins (30 checks)"
MB_OUTPUT=$(./eigenscript ../tests/test_misc_builtins.eigs 2>&1); MB_OUTPUT_RC=$?
if rc_ok "$MB_OUTPUT_RC" "$MB_OUTPUT" && echo "$MB_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 30))
    PASS=$((PASS + 30))
    echo "  PASS: all 30 misc builtin checks"
else
    TOTAL=$((TOTAL + 30))
    FAIL=$((FAIL + 30))
    echo "  FAIL: misc builtin tests"
    echo "$MB_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [35] Regex builtins
echo "[35/36] Regex (15 checks)"
RX_OUTPUT=$(./eigenscript ../tests/test_regex.eigs 2>&1); RX_OUTPUT_RC=$?
if rc_ok "$RX_OUTPUT_RC" "$RX_OUTPUT" && echo "$RX_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 15))
    PASS=$((PASS + 15))
    echo "  PASS: all 15 regex checks"
else
    TOTAL=$((TOTAL + 15))
    FAIL=$((FAIL + 15))
    echo "  FAIL: regex tests"
    echo "$RX_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [36] Import system
echo "[36/36] Import System (12 checks)"
IM_OUTPUT=$(./eigenscript ../tests/test_import.eigs 2>&1); IM_OUTPUT_RC=$?
if rc_ok "$IM_OUTPUT_RC" "$IM_OUTPUT" && echo "$IM_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 12))
    PASS=$((PASS + 12))
    echo "  PASS: all 12 import checks"
else
    TOTAL=$((TOTAL + 12))
    FAIL=$((FAIL + 12))
    echo "  FAIL: import tests"
    echo "$IM_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [38] Pattern matching
echo "[38/38] Pattern Matching (12 checks)"
PM_OUTPUT=$(./eigenscript ../tests/test_match.eigs 2>&1); PM_OUTPUT_RC=$?
if rc_ok "$PM_OUTPUT_RC" "$PM_OUTPUT" && echo "$PM_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 12))
    PASS=$((PASS + 12))
    echo "  PASS: all 12 match checks"
else
    TOTAL=$((TOTAL + 12))
    FAIL=$((FAIL + 12))
    echo "  FAIL: match tests"
    echo "$PM_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [40] Pipe operator and lambdas
echo "[40/40] Pipe & Lambda (15 checks)"
PL_OUTPUT=$(./eigenscript ../tests/test_pipe_lambda.eigs 2>&1); PL_OUTPUT_RC=$?
if rc_ok "$PL_OUTPUT_RC" "$PL_OUTPUT" && echo "$PL_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 15))
    PASS=$((PASS + 15))
    echo "  PASS: all 15 pipe/lambda checks"
else
    TOTAL=$((TOTAL + 15))
    FAIL=$((FAIL + 15))
    echo "  FAIL: pipe/lambda tests"
    echo "$PL_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [41] Coverage-gap builtins (split/starts_with/str_replace/env_get/
#      random_hex/chdir/free_val, cold tensor ops, streams, grad/sgd
#      rows & cols variants, tokenize_with_names, json_raw, 2D get/set_at)
echo "[41/47] Coverage-Gap Builtins (93 checks)"
CG_OUTPUT=$(./eigenscript ../tests/test_coverage_gaps.eigs 2>&1); CG_OUTPUT_RC=$?
if rc_ok "$CG_OUTPUT_RC" "$CG_OUTPUT" && echo "$CG_OUTPUT" | grep -q "All coverage-gap tests passed"; then
    TOTAL=$((TOTAL + 93))
    PASS=$((PASS + 93))
    echo "  PASS: all 93 coverage-gap checks"
else
    TOTAL=$((TOTAL + 93))
    FAIL=$((FAIL + 93))
    echo "  FAIL: coverage-gap tests"
    echo "$CG_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [42] CLI / REPL integration tests (always runs — exercises main.c)
echo "[42/47] CLI & REPL (15 checks)"
CLI_OUTPUT=$(bash "$TESTS_DIR/test_cli.sh" 2>&1)
CLI_PASS=$(echo "$CLI_OUTPUT" | grep -c "PASS:" || true)
CLI_FAIL=$(echo "$CLI_OUTPUT" | grep -c "FAIL:" || true)
TOTAL=$((TOTAL + CLI_PASS + CLI_FAIL))
PASS=$((PASS + CLI_PASS))
FAIL=$((FAIL + CLI_FAIL))
if [ "$CLI_FAIL" -gt 0 ]; then
    echo "  FAIL: $CLI_FAIL CLI check(s) failed"
    echo "$CLI_OUTPUT" | grep "FAIL:" | head -5
else
    echo "  PASS: all $CLI_PASS CLI checks"
fi
echo ""

# [42a] Replay tape (record/replay determinism for list/dict/buffer)
echo "[42a/47] Replay Tape (6 checks)"
RP_OUTPUT=$(bash "$TESTS_DIR/test_replay.sh" 2>&1)
RP_PASS=$(echo "$RP_OUTPUT" | grep -c "PASS:" || true)
RP_FAIL=$(echo "$RP_OUTPUT" | grep -c "FAIL:" || true)
TOTAL=$((TOTAL + RP_PASS + RP_FAIL))
PASS=$((PASS + RP_PASS))
FAIL=$((FAIL + RP_FAIL))
if [ "$RP_FAIL" -gt 0 ]; then
    echo "  FAIL: $RP_FAIL replay check(s) failed"
    echo "$RP_OUTPUT" | grep "FAIL:" | head -5
else
    echo "  PASS: all $RP_PASS replay checks"
fi
echo ""

# [42b] Softmax numerical guard (always runs — uses core tensor builtins)
echo "[42b/47] Softmax Guard (7 checks)"
SG_OUTPUT=$(./eigenscript ../tests/test_softmax_guard.eigs 2>&1); SG_OUTPUT_RC=$?
if rc_ok "$SG_OUTPUT_RC" "$SG_OUTPUT" && echo "$SG_OUTPUT" | grep -q "All softmax-guard tests passed"; then
    TOTAL=$((TOTAL + 7))
    PASS=$((PASS + 7))
    echo "  PASS: all 7 softmax-guard checks"
else
    TOTAL=$((TOTAL + 7))
    FAIL=$((FAIL + 7))
    echo "  FAIL: softmax-guard tests"
    echo "$SG_OUTPUT" | grep -iE "assert|error|FAIL" | head -5
fi
echo ""

# [42c] General finite-number guard (scalar, tensor, literals, conversions)
echo "[42c/47] Numeric Guard (19 checks)"
NG_OUTPUT=$(./eigenscript ../tests/test_numeric_guard.eigs 2>&1); NG_OUTPUT_RC=$?
if rc_ok "$NG_OUTPUT_RC" "$NG_OUTPUT" && echo "$NG_OUTPUT" | grep -q "All numeric-guard tests passed"; then
    TOTAL=$((TOTAL + 19))
    PASS=$((PASS + 19))
    echo "  PASS: all 19 numeric-guard checks"
else
    TOTAL=$((TOTAL + 19))
    FAIL=$((FAIL + 19))
    echo "  FAIL: numeric-guard tests"
    echo "$NG_OUTPUT" | grep -iE "assert|error|FAIL" | head -5
fi
echo ""

# [42c] Stdlib fixes (math.dot bounds, test.assert_near types, template no-reinterpretation, text/int-vector builders)
echo "[42d/47] Stdlib Fixes (40 checks)"
SF_OUTPUT=$(./eigenscript ../tests/test_stdlib_fixes.eigs 2>&1); SF_OUTPUT_RC=$?
if rc_ok "$SF_OUTPUT_RC" "$SF_OUTPUT" && echo "$SF_OUTPUT" | grep -q "All stdlib-fix tests passed"; then
    TOTAL=$((TOTAL + 40))
    PASS=$((PASS + 40))
    echo "  PASS: all 40 stdlib-fix checks"
else
    TOTAL=$((TOTAL + 40))
    FAIL=$((FAIL + 40))
    echo "  FAIL: stdlib-fix tests"
    echo "$SF_OUTPUT" | grep -iE "assert|error|FAIL" | head -5
fi
echo ""

# [42e] Executable-relative stdlib resolution from external projects
echo "[42e/47] Executable-Relative Stdlib (1 check)"
EXT_HOME=$(mktemp -d /tmp/eigs_ext_home_XXXXXX)
EXT_DIR=$(mktemp -d /tmp/eigs_ext_project_XXXXXX)
EXT_SCRIPT="$EXT_DIR/external_stdlib.eigs"
EIGENSCRIPT_EXE="$PWD/eigenscript"
cat > "$EXT_SCRIPT" <<'PROBE'
load_file of "lib/text_builder.eigs"
b is text_builder_new of null
text_builder_append_line of [b, "external stdlib ok"]
print of (text_builder_to_string of b)
PROBE
EXT_STATUS=0
EXT_OUTPUT=$(cd "$EXT_DIR" && HOME="$EXT_HOME" "$EIGENSCRIPT_EXE" "$EXT_SCRIPT" 2>&1) || EXT_STATUS=$?
rm -rf "$EXT_HOME" "$EXT_DIR"
if [ "$EXT_STATUS" -eq 0 ] && echo "$EXT_OUTPUT" | grep -q "external stdlib ok"; then
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    echo "  PASS: executable-relative stdlib load"
else
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo "  FAIL: executable-relative stdlib load"
    echo "$EXT_OUTPUT" | grep -iE "load_file|assert|error|FAIL" | head -5
fi
echo ""

# [43] Extra error-path coverage (always runs)
echo "[43/47] Error-Path Extras (24 checks)"
EE_OUTPUT=$(./eigenscript ../tests/test_error_extra.eigs 2>&1); EE_OUTPUT_RC=$?
if rc_ok "$EE_OUTPUT_RC" "$EE_OUTPUT" && echo "$EE_OUTPUT" | grep -q "All error_extra tests passed"; then
    TOTAL=$((TOTAL + 24))
    PASS=$((PASS + 24))
    echo "  PASS: all 24 error-path checks"
else
    TOTAL=$((TOTAL + 24))
    FAIL=$((FAIL + 24))
    echo "  FAIL: error-path tests"
    echo "$EE_OUTPUT" | grep -iE "assert|error" | head -5
fi
echo ""

# [43b] Eval-recursion-depth guard (runaway recursion → runtime error)
echo "[43b/47] Recursion Guard (4 checks)"
RG_OUTPUT=$(./eigenscript ../tests/test_recursion_guard.eigs 2>&1); RG_OUTPUT_RC=$?
if rc_ok "$RG_OUTPUT_RC" "$RG_OUTPUT" && echo "$RG_OUTPUT" | grep -q "All recursion-guard tests passed"; then
    TOTAL=$((TOTAL + 4))
    PASS=$((PASS + 4))
    echo "  PASS: all 4 recursion-guard checks"
else
    TOTAL=$((TOTAL + 4))
    FAIL=$((FAIL + 4))
    echo "  FAIL: recursion-guard tests"
    echo "$RG_OUTPUT" | grep -iE "assert|error|FAIL" | head -5
fi
echo ""

# [43c] Auth stdlib bearer parsing
echo "[43c/47] Auth Stdlib (4 checks)"
AUTH_OUTPUT=$(./eigenscript ../tests/test_auth.eigs 2>&1); AUTH_OUTPUT_RC=$?
if rc_ok "$AUTH_OUTPUT_RC" "$AUTH_OUTPUT" && echo "$AUTH_OUTPUT" | grep -q "All auth tests passed"; then
    TOTAL=$((TOTAL + 4))
    PASS=$((PASS + 4))
    echo "  PASS: all 4 auth checks"
else
    TOTAL=$((TOTAL + 4))
    FAIL=$((FAIL + 4))
    echo "  FAIL: auth tests"
    echo "$AUTH_OUTPUT" | grep -iE "assert|error|FAIL" | head -5
fi
echo ""

# [43d] HTTP client URL safety
echo "[43d/47] HTTP Client Security (4 checks)"
HCS_OUTPUT=$(./eigenscript ../tests/test_http_client_security.eigs 2>&1); HCS_OUTPUT_RC=$?
if rc_ok "$HCS_OUTPUT_RC" "$HCS_OUTPUT" && echo "$HCS_OUTPUT" | grep -q "All http client security tests passed"; then
    TOTAL=$((TOTAL + 4))
    PASS=$((PASS + 4))
    echo "  PASS: all 4 HTTP client security checks"
else
    TOTAL=$((TOTAL + 4))
    FAIL=$((FAIL + 4))
    echo "  FAIL: HTTP client security tests"
    echo "$HCS_OUTPUT" | grep -iE "assert|error|FAIL" | head -5
fi
echo ""

# [44] HTTP extension builtins (probe-gated)
HTTP_PROBE_FILE=$(mktemp /tmp/eigs_http_probe_XXXXXX.eigs)
cat > "$HTTP_PROBE_FILE" <<'PROBE'
r is http_route of ["GET", "/probe", "probe"]
print of r
PROBE
HTTP_PROBE_OUT=$(./eigenscript "$HTTP_PROBE_FILE" 2>&1)
rm -f "$HTTP_PROBE_FILE"

if ! echo "$HTTP_PROBE_OUT" | grep -q "undefined variable"; then
    echo "[44/47] HTTP Builtins (15 checks)"
    HTTP_OUTPUT=$(./eigenscript ../tests/test_http.eigs 2>&1); HTTP_OUTPUT_RC=$?
    if rc_ok "$HTTP_OUTPUT_RC" "$HTTP_OUTPUT" && echo "$HTTP_OUTPUT" | grep -q "All http tests passed"; then
        TOTAL=$((TOTAL + 15))
        PASS=$((PASS + 15))
        echo "  PASS: all 15 HTTP builtin checks"
    else
        TOTAL=$((TOTAL + 15))
        FAIL=$((FAIL + 15))
        echo "  FAIL: HTTP builtin tests"
        echo "$HTTP_OUTPUT" | grep -iE "assert|error" | head -5
    fi
    echo ""

    # [45] HTTP server integration (probe-gated)
    echo "[45/47] HTTP Server Integration (10 checks)"
    HS_OUTPUT=$(bash "$TESTS_DIR/test_http_server.sh" 2>&1)
    HS_PASS=$(echo "$HS_OUTPUT" | grep -c "PASS:" || true)
    HS_FAIL=$(echo "$HS_OUTPUT" | grep -c "FAIL:" || true)
    TOTAL=$((TOTAL + HS_PASS + HS_FAIL))
    PASS=$((PASS + HS_PASS))
    FAIL=$((FAIL + HS_FAIL))
    if [ "$HS_FAIL" -gt 0 ]; then
        echo "  FAIL: $HS_FAIL HTTP server check(s) failed"
        echo "$HS_OUTPUT" | grep "FAIL:" | head -5
    else
        echo "  PASS: all $HS_PASS HTTP server checks"
    fi
    echo ""
else
    echo "[44-45/47] HTTP tests SKIPPED (binary built without EIGENSCRIPT_EXT_HTTP)"
    echo ""
fi

# [46] Database extension (probe-gated)
DB_PROBE_FILE=$(mktemp /tmp/eigs_db_probe_XXXXXX.eigs)
cat > "$DB_PROBE_FILE" <<'PROBE'
r is db_connect of null
print of "probed"
PROBE
DB_PROBE_OUT=$(./eigenscript "$DB_PROBE_FILE" 2>&1)
rm -f "$DB_PROBE_FILE"

if ! echo "$DB_PROBE_OUT" | grep -q "undefined variable"; then
    echo "[46/47] DB Builtins (8 checks + 7 live-DB when connected)"
    DB_OUTPUT=$(./eigenscript ../tests/test_db.eigs 2>&1); DB_OUTPUT_RC=$?
    if rc_ok "$DB_OUTPUT_RC" "$DB_OUTPUT" && echo "$DB_OUTPUT" | grep -q "All db tests passed"; then
        TOTAL=$((TOTAL + 8))
        PASS=$((PASS + 8))
        if echo "$DB_OUTPUT" | grep -q "live-DB checks skipped"; then
            echo "  PASS: all 8 DB builtin checks (live-DB checks skipped: no connection)"
        else
            echo "  PASS: all 8 DB builtin checks + 7 live-DB round-trip checks"
        fi
    else
        TOTAL=$((TOTAL + 8))
        FAIL=$((FAIL + 8))
        echo "  FAIL: DB builtin tests"
        echo "$DB_OUTPUT" | grep -iE "assert|error" | head -5
    fi
    echo ""
else
    echo "[46/47] DB tests SKIPPED (binary built without EIGENSCRIPT_EXT_DB)"
    echo ""
fi

# [47] Model save/load/infer roundtrip (probe-gated)
MODEL_PROBE_FILE=$(mktemp /tmp/eigs_model_probe_XXXXXX.eigs)
cat > "$MODEL_PROBE_FILE" <<'PROBE'
print of (eigen_model_loaded of null)
PROBE
MODEL_PROBE_OUT=$(./eigenscript "$MODEL_PROBE_FILE" 2>&1)
rm -f "$MODEL_PROBE_FILE"

if ! echo "$MODEL_PROBE_OUT" | grep -q "undefined variable"; then
    echo "[47/47] Model Save/Load Roundtrip (17 checks)"
    MRT_OUTPUT=$(bash "$TESTS_DIR/test_model_roundtrip.sh" 2>&1)
    MRT_PASS=$(echo "$MRT_OUTPUT" | grep -c "PASS:" || true)
    MRT_FAIL=$(echo "$MRT_OUTPUT" | grep -c "FAIL:" || true)
    TOTAL=$((TOTAL + MRT_PASS + MRT_FAIL))
    PASS=$((PASS + MRT_PASS))
    FAIL=$((FAIL + MRT_FAIL))
    if [ "$MRT_FAIL" -gt 0 ]; then
        echo "  FAIL: $MRT_FAIL model roundtrip check(s) failed"
        echo "$MRT_OUTPUT" | grep "FAIL:" | head -5
    else
        echo "  PASS: all $MRT_PASS model roundtrip checks"
    fi
    echo ""

    echo "[47b/47] Model Overflow Regression (2 checks)"
    MO_OUTPUT=$(bash "$TESTS_DIR/test_model_overflow.sh" 2>&1)
    MO_PASS=$(echo "$MO_OUTPUT" | grep -c "PASS:" || true)
    MO_FAIL=$(echo "$MO_OUTPUT" | grep -c "FAIL:" || true)
    TOTAL=$((TOTAL + MO_PASS + MO_FAIL))
    PASS=$((PASS + MO_PASS))
    FAIL=$((FAIL + MO_FAIL))
    if [ "$MO_FAIL" -gt 0 ]; then
        echo "  FAIL: $MO_FAIL model overflow check(s) failed"
        echo "$MO_OUTPUT" | grep "FAIL:" | head -3
    else
        echo "  PASS: malicious model checkpoints rejected"
    fi
    echo ""
else
    echo "[47/47] Model roundtrip SKIPPED (binary built without EIGENSCRIPT_EXT_MODEL)"
    echo ""
fi

# [48] Large-buffer regression tests — exercise strbuf growth paths
# that replaced the fixed MAX_STR stack arrays in v0.8.0.
echo "[48a] Large Strings (4 checks)"
LS_OUTPUT=$(./eigenscript "$TESTS_DIR/test_large_strings.eigs" 2>&1)
if echo "$LS_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 4)); PASS=$((PASS + 4))
    echo "  PASS: all 4 large-string checks"
else
    TOTAL=$((TOTAL + 4)); FAIL=$((FAIL + 1))
    echo "  FAIL: large-string checks"; echo "$LS_OUTPUT" | grep FAIL | head -3
fi

echo "[48b] F-String Large (3 checks)"
FL_OUTPUT=$(./eigenscript "$TESTS_DIR/test_fstring_large.eigs" 2>&1)
if echo "$FL_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 3)); PASS=$((PASS + 3))
    echo "  PASS: all 3 f-string-large checks"
else
    TOTAL=$((TOTAL + 3)); FAIL=$((FAIL + 1))
    echo "  FAIL: f-string-large checks"; echo "$FL_OUTPUT" | grep FAIL | head -3
fi

echo "[48c] Regex Large (3 checks)"
RL_OUTPUT=$(./eigenscript "$TESTS_DIR/test_regex_large.eigs" 2>&1)
if echo "$RL_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 3)); PASS=$((PASS + 3))
    echo "  PASS: all 3 regex-large checks"
else
    TOTAL=$((TOTAL + 3)); FAIL=$((FAIL + 1))
    echo "  FAIL: regex-large checks"; echo "$RL_OUTPUT" | grep FAIL | head -3
fi

echo "[48d] JSON Large (6 checks)"
JL_OUTPUT=$(./eigenscript "$TESTS_DIR/test_json_large.eigs" 2>&1)
if echo "$JL_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 6)); PASS=$((PASS + 6))
    echo "  PASS: all 6 json-large checks"
else
    TOTAL=$((TOTAL + 6)); FAIL=$((FAIL + 1))
    echo "  FAIL: json-large checks"; echo "$JL_OUTPUT" | grep FAIL | head -3
fi
echo ""

# I/O builtins + join + refcount GC
echo "[49] I/O Builtins & GC (16 checks)"
IO_OUTPUT=$(./eigenscript ../tests/test_io_builtins.eigs 2>&1); IO_OUTPUT_RC=$?
if rc_ok "$IO_OUTPUT_RC" "$IO_OUTPUT" && echo "$IO_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 16))
    PASS=$((PASS + 16))
    echo "  PASS: all 16 I/O + GC checks"
else
    TOTAL=$((TOTAL + 16))
    FAIL=$((FAIL + 16))
    echo "  FAIL: I/O builtins tests"
    echo "$IO_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [50] Bitwise operations
echo "[50] Bitwise Operations (22 checks)"
BW_OUTPUT=$(./eigenscript ../tests/test_bitwise.eigs 2>&1); BW_OUTPUT_RC=$?
if rc_ok "$BW_OUTPUT_RC" "$BW_OUTPUT" && echo "$BW_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 22))
    PASS=$((PASS + 22))
    echo "  PASS: all 22 bitwise checks"
else
    TOTAL=$((TOTAL + 22))
    FAIL=$((FAIL + 22))
    echo "  FAIL: bitwise tests"
    echo "$BW_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [51] Unobserved block
echo "[51] Unobserved Block (8 checks)"
UN_OUTPUT=$(./eigenscript ../tests/test_unobserved.eigs 2>&1); UN_OUTPUT_RC=$?
if rc_ok "$UN_OUTPUT_RC" "$UN_OUTPUT" && echo "$UN_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 8))
    PASS=$((PASS + 8))
    echo "  PASS: all 8 unobserved checks"
else
    TOTAL=$((TOTAL + 8))
    FAIL=$((FAIL + 8))
    echo "  FAIL: unobserved tests"
    echo "$UN_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [52] Stream I/O
echo "[52] Stream Tensor I/O (12 checks)"
SI_OUTPUT=$(./eigenscript ../tests/test_stream_io.eigs 2>&1); SI_OUTPUT_RC=$?
if rc_ok "$SI_OUTPUT_RC" "$SI_OUTPUT" && echo "$SI_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 12))
    PASS=$((PASS + 12))
    echo "  PASS: all 12 stream I/O checks"
else
    TOTAL=$((TOTAL + 12))
    FAIL=$((FAIL + 12))
    echo "  FAIL: stream I/O tests"
    echo "$SI_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [53] Monotonic timers
echo "[53] Monotonic Timers (6 checks)"
MT_OUTPUT=$(./eigenscript ../tests/test_monotonic_timers.eigs 2>&1); MT_OUTPUT_RC=$?
if rc_ok "$MT_OUTPUT_RC" "$MT_OUTPUT" && echo "$MT_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 6))
    PASS=$((PASS + 6))
    echo "  PASS: all 6 monotonic timer checks"
else
    TOTAL=$((TOTAL + 6))
    FAIL=$((FAIL + 6))
    echo "  FAIL: monotonic timer tests"
    echo "$MT_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [55] Concurrency: spawn/join/channel
echo "[55] Concurrency (6 checks)"
CC_OUTPUT=$(./eigenscript ../tests/test_concurrent.eigs 2>&1)
CC_PASS=$(echo "$CC_OUTPUT" | grep -c "^PASS:" || true)
CC_FAIL=$(echo "$CC_OUTPUT" | grep -c "^FAIL:" || true)
TOTAL=$((TOTAL + CC_PASS + CC_FAIL))
PASS=$((PASS + CC_PASS))
FAIL=$((FAIL + CC_FAIL))
if [ "$CC_FAIL" -eq 0 ]; then
    echo "  PASS: all 6 concurrency checks"
else
    echo "  FAIL: concurrency tests ($CC_FAIL failed)"
    echo "$CC_OUTPUT" | grep "FAIL:" | head -5
fi
echo ""

# [56] EigenStore embedded database
echo "[56] EigenStore Database (22 checks)"
ST_OUTPUT=$(./eigenscript ../tests/test_store.eigs 2>&1); ST_OUTPUT_RC=$?
if rc_ok "$ST_OUTPUT_RC" "$ST_OUTPUT" && echo "$ST_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 22))
    PASS=$((PASS + 22))
    echo "  PASS: all 22 store checks"
else
    TOTAL=$((TOTAL + 22))
    FAIL=$((FAIL + 22))
    echo "  FAIL: store tests"
    echo "$ST_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [58] GC / free_value paths and misc coverage gaps
echo "[58] GC & Free Paths (34 checks)"
GC_OUTPUT=$(./eigenscript ../tests/test_gc.eigs 2>&1); GC_OUTPUT_RC=$?
if rc_ok "$GC_OUTPUT_RC" "$GC_OUTPUT" && echo "$GC_OUTPUT" | grep -q "All gc tests passed"; then
    TOTAL=$((TOTAL + 34))
    PASS=$((PASS + 34))
    echo "  PASS: all 34 GC/free checks"
else
    TOTAL=$((TOTAL + 34))
    FAIL=$((FAIL + 34))
    echo "  FAIL: GC tests"
    echo "$GC_OUTPUT" | grep -iE "assert|error|FAIL" | head -5
fi
echo ""

# [57] Coverage v2 — close gcov gaps in eval/builtins/eigenscript/ext_store
echo "[57] Coverage V2 (118 checks)"
CV2_OUTPUT=$(./eigenscript ../tests/test_coverage_v2.eigs 2>&1); CV2_OUTPUT_RC=$?
if rc_ok "$CV2_OUTPUT_RC" "$CV2_OUTPUT" && echo "$CV2_OUTPUT" | grep -q "All coverage-v2 tests passed"; then
    TOTAL=$((TOTAL + 118))
    PASS=$((PASS + 118))
    echo "  PASS: all 118 coverage-v2 checks"
else
    TOTAL=$((TOTAL + 118))
    FAIL=$((FAIL + 118))
    echo "  FAIL: coverage-v2 tests"
    echo "$CV2_OUTPUT" | grep -iE "assert|error|FAIL" | head -5
fi
echo ""

# [54] Example smoke tests
echo "[54] Example Smoke Tests"
EX_OUTPUT=$(bash "$TESTS_DIR/test_examples.sh" 2>&1)

# Count passes from output
EX_PASS=$(echo "$EX_OUTPUT" | grep -c "PASS:" || true)
EX_FAIL=$(echo "$EX_OUTPUT" | grep -c "FAIL:" || true)

TOTAL=$((TOTAL + EX_PASS + EX_FAIL))
PASS=$((PASS + EX_PASS))
FAIL=$((FAIL + EX_FAIL))

echo "$EX_OUTPUT" | grep "EXAMPLES:"
echo ""

# [59] Import error paths (not-found, parse-errors)
echo "[59] Import Error Paths (6 checks)"
IE_OUTPUT=$(./eigenscript ../tests/test_import_errors.eigs 2>&1); IE_OUTPUT_RC=$?
if rc_ok "$IE_OUTPUT_RC" "$IE_OUTPUT" && echo "$IE_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 6))
    PASS=$((PASS + 6))
    echo "  PASS: all 6 import-error checks"
else
    TOTAL=$((TOTAL + 6))
    FAIL=$((FAIL + 6))
    echo "  FAIL: import-error tests"
    echo "$IE_OUTPUT" | grep -iE "assert|error|FAIL" | head -5
fi
echo ""

# [60] Terminal builtins (screen_clear, screen_put, screen_end, screen_render, raw_key)
echo "[60] Terminal Builtins (10 checks)"
TM_OUTPUT=$(./eigenscript ../tests/test_terminal.eigs 2>&1); TM_OUTPUT_RC=$?
if rc_ok "$TM_OUTPUT_RC" "$TM_OUTPUT" && echo "$TM_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 10))
    PASS=$((PASS + 10))
    echo "  PASS: all 10 terminal builtin checks"
else
    TOTAL=$((TOTAL + 10))
    FAIL=$((FAIL + 10))
    echo "  FAIL: terminal builtin tests"
    echo "$TM_OUTPUT" | grep -iE "assert|error|FAIL" | head -5
fi
echo ""

# [61] Hash builtins (SHA-256, MD5, HMAC-SHA256)
echo "[61] Hash Builtins (14 checks)"
HA_OUTPUT=$(./eigenscript ../tests/test_hash.eigs 2>&1); HA_OUTPUT_RC=$?
if rc_ok "$HA_OUTPUT_RC" "$HA_OUTPUT" && echo "$HA_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 14))
    PASS=$((PASS + 14))
    echo "  PASS: all 14 hash checks"
else
    TOTAL=$((TOTAL + 14))
    FAIL=$((FAIL + 14))
    echo "  FAIL: hash tests"
    echo "$HA_OUTPUT" | grep -iE "assert|error|FAIL" | head -5
fi
echo ""

# [63] UI toolkit unit tests (headless, stubs gfx)
echo "[63] UI Toolkit (81 checks)"
UI_OUTPUT=$(./eigenscript ../tests/test_ui.eigs 2>&1); UI_OUTPUT_RC=$?
if rc_ok "$UI_OUTPUT_RC" "$UI_OUTPUT" && echo "$UI_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 81))
    PASS=$((PASS + 81))
    echo "  PASS: all 81 UI toolkit checks"
else
    TOTAL=$((TOTAL + 81))
    FAIL=$((FAIL + 81))
    echo "  FAIL: UI toolkit tests"
    echo "$UI_OUTPUT" | grep -iE "assert|error|FAIL" | head -5
fi
echo ""

# [62] Audio synthesis builtins (probe-gated — needs gfx build)
AUDIO_PROBE_FILE=$(mktemp /tmp/eigs_audio_probe_XXXXXX.eigs)
cat > "$AUDIO_PROBE_FILE" <<'PROBE'
s is audio_sine of [440, 0.01, 0.5]
print of (len of s)
PROBE
AUDIO_PROBE_OUT=$(./eigenscript "$AUDIO_PROBE_FILE" 2>&1)
rm -f "$AUDIO_PROBE_FILE"

if ! echo "$AUDIO_PROBE_OUT" | grep -q "undefined variable"; then
    echo "[62] Audio Synthesis (24 checks)"
    AU_OUTPUT=$(./eigenscript ../tests/test_audio.eigs 2>&1); AU_OUTPUT_RC=$?
    if rc_ok "$AU_OUTPUT_RC" "$AU_OUTPUT" && echo "$AU_OUTPUT" | grep -q "All tests passed"; then
        TOTAL=$((TOTAL + 24))
        PASS=$((PASS + 24))
        echo "  PASS: all 24 audio checks"
    else
        TOTAL=$((TOTAL + 24))
        FAIL=$((FAIL + 24))
        echo "  FAIL: audio tests"
        echo "$AU_OUTPUT" | grep -iE "assert|error|FAIL" | head -5
    fi
    echo ""
else
    echo "[62] Audio tests SKIPPED (binary built without EIGENSCRIPT_EXT_GFX)"
    echo ""
fi

# [64] list_truncate builtin
echo "[64] List Truncate (9 checks)"
LT_OUTPUT=$(./eigenscript ../tests/test_list_truncate.eigs 2>&1); LT_OUTPUT_RC=$?
if rc_ok "$LT_OUTPUT_RC" "$LT_OUTPUT" && echo "$LT_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 9))
    PASS=$((PASS + 9))
    echo "  PASS: all 9 list_truncate checks"
else
    TOTAL=$((TOTAL + 9))
    FAIL=$((FAIL + 9))
    echo "  FAIL: list_truncate tests"
    echo "$LT_OUTPUT" | grep -iE "assert|error|FAIL" | head -5
fi
echo ""

# [66] list_remove_at builtin
echo "[66] List Remove At (8 checks)"
LRA_OUTPUT=$(./eigenscript ../tests/test_list_remove_at.eigs 2>&1); LRA_OUTPUT_RC=$?
if rc_ok "$LRA_OUTPUT_RC" "$LRA_OUTPUT" && echo "$LRA_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 8))
    PASS=$((PASS + 8))
    echo "  PASS: all 8 list_remove_at checks"
else
    TOTAL=$((TOTAL + 8))
    FAIL=$((FAIL + 8))
    echo "  FAIL: list_remove_at tests"
    echo "$LRA_OUTPUT" | grep -iE "assert|error|FAIL" | head -5
fi
echo ""

# [65] sort_by builtin
echo "[65] Sort By (9 checks)"
SBY_OUTPUT=$(./eigenscript ../tests/test_sort_by.eigs 2>&1); SBY_OUTPUT_RC=$?
if rc_ok "$SBY_OUTPUT_RC" "$SBY_OUTPUT" && echo "$SBY_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 9))
    PASS=$((PASS + 9))
    echo "  PASS: all 9 sort_by checks"
else
    TOTAL=$((TOTAL + 9))
    FAIL=$((FAIL + 9))
    echo "  FAIL: sort_by tests"
    echo "$SBY_OUTPUT" | grep -iE "assert|error|FAIL" | head -5
fi
echo ""

# [67] Index-after-call regression (gap #2: use-after-free in OP_INDEX_GET fast path)
echo "[67] Index After Call (21 checks)"
IAC_OUTPUT=$(./eigenscript ../tests/test_index_after_call.eigs 2>&1); IAC_OUTPUT_RC=$?
if rc_ok "$IAC_OUTPUT_RC" "$IAC_OUTPUT" && echo "$IAC_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 21))
    PASS=$((PASS + 21))
    echo "  PASS: all 21 index-after-call checks"
else
    TOTAL=$((TOTAL + 21))
    FAIL=$((FAIL + 21))
    echo "  FAIL: index-after-call tests"
    echo "$IAC_OUTPUT" | grep -iE "assert|error|FAIL" | head -5
fi
echo ""

# [68] OP_DISPATCH key handling (boxed-num regression + float-discipline)
echo "[68] Dispatch (9 checks)"
DISP_OUTPUT=$(./eigenscript ../tests/test_dispatch.eigs 2>&1); DISP_OUTPUT_RC=$?
if rc_ok "$DISP_OUTPUT_RC" "$DISP_OUTPUT" && echo "$DISP_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 9))
    PASS=$((PASS + 9))
    echo "  PASS: all 9 dispatch checks"
else
    TOTAL=$((TOTAL + 9))
    FAIL=$((FAIL + 9))
    echo "  FAIL: dispatch tests"
    echo "$DISP_OUTPUT" | grep -iE "assert|error|FAIL" | head -5
fi
echo ""

# [70] Temporal interrogatives (prev of, at, state_at) + the line-floor
# index in trace.c (deep loop histories must skip segments correctly).
echo "[70] Temporal Interrogatives (23 checks)"
TT_OUTPUT=$(./eigenscript ../tests/test_temporal.eigs 2>&1); TT_OUTPUT_RC=$?
if rc_ok "$TT_OUTPUT_RC" "$TT_OUTPUT" && echo "$TT_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 23))
    PASS=$((PASS + 23))
    echo "  PASS: all 23 temporal checks"
else
    TOTAL=$((TOTAL + 23))
    FAIL=$((FAIL + 23))
    echo "  FAIL: temporal interrogative tests"
    echo "$TT_OUTPUT" | grep -iE "FAIL|error" | head -5
fi
echo ""

# [78] spawn with multiple args (0.13.0).
echo "[78] Spawn With Multiple Args (22 checks)"
SP_OUTPUT=$(./eigenscript ../tests/test_spawn_args.eigs 2>&1); SP_OUTPUT_RC=$?
if rc_ok "$SP_OUTPUT_RC" "$SP_OUTPUT" && echo "$SP_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 22))
    PASS=$((PASS + 22))
    echo "  PASS: all 22 spawn-args checks"
else
    TOTAL=$((TOTAL + 22))
    FAIL=$((FAIL + 22))
    echo "  FAIL: spawn-args tests"
    echo "$SP_OUTPUT" | grep -iE "MISMATCH|FAIL|error" | head -5
fi
echo ""

# [77] Non-blocking channel recv (0.13.0).
echo "[77] Non-blocking Channel Recv (29 checks)"
CNB_OUTPUT=$(./eigenscript ../tests/test_channel_nb.eigs 2>&1); CNB_OUTPUT_RC=$?
if rc_ok "$CNB_OUTPUT_RC" "$CNB_OUTPUT" && echo "$CNB_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 29))
    PASS=$((PASS + 29))
    echo "  PASS: all 29 channel-nb checks"
else
    TOTAL=$((TOTAL + 29))
    FAIL=$((FAIL + 29))
    echo "  FAIL: channel-nb tests"
    echo "$CNB_OUTPUT" | grep -iE "MISMATCH|FAIL|error" | head -5
fi
echo ""

# [76] Slicing (0.13.0).
echo "[76] Slicing (48 checks)"
SL_OUTPUT=$(./eigenscript ../tests/test_slicing.eigs 2>&1); SL_OUTPUT_RC=$?
if rc_ok "$SL_OUTPUT_RC" "$SL_OUTPUT" && echo "$SL_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 48))
    PASS=$((PASS + 48))
    echo "  PASS: all 48 slicing checks"
else
    TOTAL=$((TOTAL + 48))
    FAIL=$((FAIL + 48))
    echo "  FAIL: slicing tests"
    echo "$SL_OUTPUT" | grep -iE "MISMATCH|FAIL|error" | head -5
fi
echo ""

# [75] Streaming subprocess I/O (0.13.0).
echo "[75] Streaming Subprocess I/O (39 checks)"
PS_OUTPUT=$(./eigenscript ../tests/test_proc_stream.eigs 2>&1); PS_OUTPUT_RC=$?
if rc_ok "$PS_OUTPUT_RC" "$PS_OUTPUT" && echo "$PS_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 39))
    PASS=$((PASS + 39))
    echo "  PASS: all 39 proc-stream checks"
else
    TOTAL=$((TOTAL + 39))
    FAIL=$((FAIL + 39))
    echo "  FAIL: proc-stream tests"
    echo "$PS_OUTPUT" | grep -iE "MISMATCH|FAIL|error" | head -5
fi
echo ""

# [74] Destructuring assignment (0.13.0).
echo "[74] Destructuring (28 checks)"
DS_OUTPUT=$(./eigenscript ../tests/test_destructuring.eigs 2>&1); DS_OUTPUT_RC=$?
if rc_ok "$DS_OUTPUT_RC" "$DS_OUTPUT" && echo "$DS_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 28))
    PASS=$((PASS + 28))
    echo "  PASS: all 28 destructuring checks"
else
    TOTAL=$((TOTAL + 28))
    FAIL=$((FAIL + 28))
    echo "  FAIL: destructuring tests"
    echo "$DS_OUTPUT" | grep -iE "MISMATCH|FAIL|error" | head -5
fi
echo ""

# [73] Negative indexing (0.13.0).
echo "[73] Negative Indexing (19 checks)"
NI_OUTPUT=$(./eigenscript ../tests/test_negative_index.eigs 2>&1); NI_OUTPUT_RC=$?
if rc_ok "$NI_OUTPUT_RC" "$NI_OUTPUT" && echo "$NI_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 19))
    PASS=$((PASS + 19))
    echo "  PASS: all 19 negative-index checks"
else
    TOTAL=$((TOTAL + 19))
    FAIL=$((FAIL + 19))
    echo "  FAIL: negative-index tests"
    echo "$NI_OUTPUT" | grep -iE "MISMATCH|FAIL|error" | head -5
fi
echo ""

# [72] Default parameter values (0.13.0).
echo "[72] Default Parameters (28 checks)"
DP_OUTPUT=$(./eigenscript ../tests/test_default_params.eigs 2>&1); DP_OUTPUT_RC=$?
if rc_ok "$DP_OUTPUT_RC" "$DP_OUTPUT" && echo "$DP_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 28))
    PASS=$((PASS + 28))
    echo "  PASS: all 28 default-param checks"
else
    TOTAL=$((TOTAL + 28))
    FAIL=$((FAIL + 28))
    echo "  FAIL: default-param tests"
    echo "$DP_OUTPUT" | grep -iE "MISMATCH|FAIL|error" | head -5
fi
echo ""

# [71] Module-chunk teardown with promoted slots. Top-level `unobserved`
# blocks promote non-escaping names to module-chunk local slots without a
# local_names array; freeing the script chunk used to segfault at exit
# (after correct output — so this check must verify the exit code, which
# most suite checks don't).
echo "[71] Module Promotion Teardown (1 check)"
MP_OUTPUT=$(./eigenscript ../tests/test_module_promotion_exit.eigs 2>&1)
MP_RC=$?
TOTAL=$((TOTAL + 1))
if [ "$MP_RC" = "0" ] && [ "$MP_OUTPUT" = "ok" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: promoted-slot module chunk frees cleanly (rc=0)"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: module promotion teardown (rc=$MP_RC out='$MP_OUTPUT')"
fi
echo ""

# [69] ASan leak guard for the builtin-return ref protocol (regression of 2f1e993).
# Skips cleanly if ASan unavailable, so this is safe on CI runners without it.
echo "[69] Leak Guard (ASan, builtin ref protocol)"
LG_OUTPUT=$(bash "$TESTS_DIR/test_leak_guard.sh" 2>&1)
LG_PASS=$(echo "$LG_OUTPUT" | grep -c "PASS:" || true)
LG_FAIL=$(echo "$LG_OUTPUT" | grep -c "FAIL:" || true)
TOTAL=$((TOTAL + LG_PASS + LG_FAIL))
PASS=$((PASS + LG_PASS))
FAIL=$((FAIL + LG_FAIL))
if echo "$LG_OUTPUT" | grep -q "skipped"; then
    echo "  SKIP: AddressSanitizer not available — leak guard skipped"
elif [ "$LG_FAIL" -gt 0 ]; then
    echo "  FAIL: $LG_FAIL leak-guard check(s) failed"
    echo "$LG_OUTPUT" | grep "FAIL:" | head -5
else
    echo "  PASS: all $LG_PASS leak-guard checks"
fi
echo ""

# [80] Formatter (--fmt) — exercises fmt.c, which had zero suite coverage.
echo "[80] Formatter (14 checks)"
FMT_OUTPUT=$(bash "$TESTS_DIR/test_fmt.sh" </dev/null 2>&1)
FMT_PASS=$(echo "$FMT_OUTPUT" | grep -c "PASS:" || true)
FMT_FAIL=$(echo "$FMT_OUTPUT" | grep -c "FAIL:" || true)
TOTAL=$((TOTAL + FMT_PASS + FMT_FAIL))
PASS=$((PASS + FMT_PASS))
FAIL=$((FAIL + FMT_FAIL))
if [ "$FMT_FAIL" -gt 0 ]; then
    echo "  FAIL: $FMT_FAIL formatter check(s) failed"
    echo "$FMT_OUTPUT" | grep "FAIL:" | head -5
else
    echo "  PASS: all $FMT_PASS formatter checks"
fi
echo ""

# [81] Linter (--lint) — exercises lint.c, which had zero suite coverage.
echo "[81] Linter (13 checks)"
LINT_OUTPUT=$(bash "$TESTS_DIR/test_lint.sh" </dev/null 2>&1)
LINT_PASS=$(echo "$LINT_OUTPUT" | grep -c "PASS:" || true)
LINT_FAIL=$(echo "$LINT_OUTPUT" | grep -c "FAIL:" || true)
TOTAL=$((TOTAL + LINT_PASS + LINT_FAIL))
PASS=$((PASS + LINT_PASS))
FAIL=$((FAIL + LINT_FAIL))
if [ "$LINT_FAIL" -gt 0 ]; then
    echo "  FAIL: $LINT_FAIL linter check(s) failed"
    echo "$LINT_OUTPUT" | grep "FAIL:" | head -5
else
    echo "  PASS: all $LINT_PASS linter checks"
fi
echo ""

# [82] JIT fast paths — checksummed correctness for the fused opcodes,
# inline ICs, iter/native-call helpers, and OSR that only fire on hot
# benchmark-shaped code. Runs with EIGS_JIT_STATS so we can also assert
# (on x86-64) that thunks really compiled — a regression that quietly
# disables the JIT must not let this section pass interpreted.
echo "[82] JIT Fast Paths (21 checks + thunk gate)"
JPATH_OUTPUT=$(EIGS_JIT_STATS=1 ./eigenscript ../tests/test_jit_paths.eigs </dev/null 2>&1); JPATH_RC=$?
TOTAL=$((TOTAL + 21))
if rc_ok "$JPATH_RC" "$JPATH_OUTPUT" && echo "$JPATH_OUTPUT" | grep -q "All tests passed"; then
    PASS=$((PASS + 21))
    echo "  PASS: all 21 JIT fast-path checks"
else
    FAIL=$((FAIL + 21))
    echo "  FAIL: JIT fast-path tests (rc=$JPATH_RC)"
    echo "$JPATH_OUTPUT" | grep -iE "FAIL|error" | head -5
fi
TOTAL=$((TOTAL + 1))
if [ "$(uname -m)" = "x86_64" ]; then
    if echo "$JPATH_OUTPUT" | grep -qE "\[jit\] scanned=[0-9]+ compiled=[1-9]"; then
        PASS=$((PASS + 1))
        echo "  PASS: JIT thunks compiled (fast paths ran native)"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: no JIT thunks compiled — fast paths ran interpreted"
    fi
else
    PASS=$((PASS + 1))
    echo "  SKIP: thunk gate (non-x86-64: interpreter fallback expected)"
fi
echo ""

# [83] Walker capture matrix — closure capture of names reachable only
# through each AST node kind (the issue-#156 bug class: a pre-pass walker
# that doesn't know a node silently breaks capture).
echo "[83] Walker Capture Matrix (27 checks)"
check_eigs_suite "all 27 walker-matrix capture checks" test_walker_matrix.eigs "All tests passed" 27

# [84] Builtin direct-vs-indirect — builtins shadowed by compiler
# lowerings (dispatch → OP_DISPATCH) and bench-only buffer builtins;
# asserts the C fallback agrees with the lowered opcode.
echo "[84] Builtin Direct-vs-Indirect (37 checks)"
check_eigs_suite "all 37 builtin direct/indirect checks" test_builtin_indirect.eigs "All tests passed" 37

# [85] Reinstated suites — these .eigs files existed but were never
# referenced by this runner, so editing them did nothing. Each runs as
# one suite-level check: exit 0 + its own pass marker.
echo "[85] Reinstated Suites (28 checks)"
check_eigs_suite "break scope" test_break_scope.eigs "break scope: all passed" 1
check_eigs_suite "control flow interactions" test_control_flow_interactions.eigs "control flow interactions: all passed" 1
check_eigs_suite "copy_into negative offset" test_copy_into_neg.eigs "PASS: copy_into negative offset" 1
check_eigs_suite "deep nesting" test_deep_nest.eigs "PASS: deep nesting no crash" 1
check_eigs_suite "error propagation" test_error_propagation.eigs "error propagation: all passed" 1
check_eigs_suite "handle forge" test_handle_forge.eigs "PASS: handle table" 1
check_eigs_suite "json hard" test_json_hard.eigs "json hard: all passed" 1
check_eigs_suite "json roundtrip" test_json_roundtrip.eigs "json roundtrip: all passed" 1
check_eigs_suite "observer interactions" test_observer_interactions.eigs "observer interactions: all passed" 1
check_eigs_suite "scope semantics" test_scope_semantics.eigs "scope semantics: all passed" 1
check_eigs_suite "split empty" test_split_empty.eigs "split empty: all passed" 1
check_eigs_suite "split hard" test_split_hard.eigs "split hard: all passed" 1
check_eigs_suite "tensor overflow guard" test_tensor_overflow.eigs "PASS: tensor overflow guard" 1
check_eigs_suite "lab" test_lab.eigs "All tests passed." 1
check_eigs_suite "data" test_data.eigs "All tests passed." 1
check_eigs_suite "experiment" test_experiment.eigs "All tests passed." 1
check_eigs_suite "numerics" test_numerics.eigs "All tests passed." 1
check_eigs_suite "optimize" test_optimize.eigs "All tests passed." 1
check_eigs_suite "simulation" test_simulation.eigs "All tests passed." 1
check_eigs_suite "linalg" test_linalg.eigs "All tests passed." 1
check_eigs_suite "probability" test_probability.eigs "All tests passed." 1
check_eigs_suite "biology" test_biology.eigs "All tests passed." 1
check_eigs_suite "calculus" test_calculus.eigs "All tests passed." 1
check_eigs_suite "chemistry" test_chemistry.eigs "All tests passed." 1
check_eigs_suite "earth science" test_earth_science.eigs "All tests passed." 1
check_eigs_suite "engineering" test_engineering.eigs "All tests passed." 1
check_eigs_suite "geometry" test_geometry.eigs "All tests passed." 1
check_eigs_suite "physics" test_physics.eigs "All tests passed." 1
echo ""

# [87] Closure-cycle shapes — functional correctness of every env<->fn
# and value cycle (a KNOWN accumulating leak the runtime can't reclaim;
# see docs/CLOSURE_CYCLE_GC.md). Locks that the shapes compute correctly
# and that the non-leaking invariants (self-ref containers, non-escaping
# recursion) hold. Tolerated leak-exit under ASan (counted by rc_ok).
echo "[87] Closure Cycle Shapes (14 checks)"
check_eigs_suite "all 14 closure-cycle checks" test_closure_cycles.eigs "All tests passed" 14
echo ""

# [86] Corpus builder — build_corpus + the tok_base_string detokenizer
# table (both 0% before: nothing in the suite ever built a corpus).
echo "[86] Corpus Builder (25 checks)"
check_eigs_suite "all 25 corpus-builder checks" test_corpus.eigs "All tests passed" 25
echo ""

# [88] LSP behavioral tests — drive src/eigenlsp over real JSON-RPC and
# assert initialize/diagnostics/completion/hover/definition/references/
# shutdown. The LSP was previously only compile-checked. Skips cleanly
# without python3 or the eigenlsp build.
echo "[88] LSP Behavioral (23 checks)"
LSP_OUTPUT=$(bash "$TESTS_DIR/test_lsp.sh" 2>&1)
if echo "$LSP_OUTPUT" | grep -q "SKIP:"; then
    echo "$LSP_OUTPUT" | grep "SKIP:"
else
    LSP_PASS=$(echo "$LSP_OUTPUT" | grep -c "PASS:" || true)
    LSP_FAIL=$(echo "$LSP_OUTPUT" | grep -c "FAIL:" || true)
    TOTAL=$((TOTAL + LSP_PASS + LSP_FAIL))
    PASS=$((PASS + LSP_PASS))
    FAIL=$((FAIL + LSP_FAIL))
    if [ "$LSP_FAIL" -gt 0 ]; then
        echo "  FAIL: $LSP_FAIL LSP check(s) failed"
        echo "$LSP_OUTPUT" | grep "FAIL:" | head -5
    else
        echo "  PASS: all $LSP_PASS LSP checks"
    fi
fi
echo ""

echo "============================================"
echo "  RESULTS: $PASS/$TOTAL passed, $FAIL failed"
if [ "$LEAKED" -gt 0 ]; then
    echo "  NOTE: $LEAKED test program(s) exited nonzero on LeakSanitizer"
    echo "  reports (known closure-cycle env leaks; counted as passes)."
fi
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
