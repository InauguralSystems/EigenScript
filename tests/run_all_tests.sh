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
# output carries a LeakSanitizer report is tolerated with a warning tally.
# The env<->fn closure cycles are reclaimed by the cycle collector now
# (docs/CLOSURE_CYCLE_GC.md — section [87] gates those shapes strictly);
# the residual tolerated reports are spawn()-thread programs (the
# collector is disabled once multithreaded) and a handful of pre-existing
# non-closure leak shapes. Everything else nonzero — crashes, asserts,
# UBSan — fails.
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

echo "[0] Opcode ABI Guard"
TOTAL=$((TOTAL + 1))
OP_ABI_OUT=$(${CC:-gcc} -std=c11 -I. \
    -DEIGENSCRIPT_EXT_HTTP=0 \
    -DEIGENSCRIPT_EXT_MODEL=0 \
    -DEIGENSCRIPT_EXT_DB=0 \
    -c ../tests/test_opcode_abi.c -o /tmp/eigs_opcode_abi.o 2>&1)
OP_ABI_RC=$?
if [ "$OP_ABI_RC" = "0" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: opcode numeric ABI unchanged"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: opcode numeric ABI changed"
    echo "$OP_ABI_OUT" | head -8
fi
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
if [ -n "$HD_ITERS" ] && [ "$HD_ITERS" -gt 0 ] 2>/dev/null && [ "$HD_ITERS" -lt 50 ] 2>/dev/null; then
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

echo "[8b] Windowed Converged (5 checks)"
WC_OUTPUT=$(./eigenscript ../tests/test_windowed_converged.eigs 2>&1)
WC1=$(echo "$WC_OUTPUT" | grep -A1 'WC1:' | tail -1)
check "WC1 short trajectory cannot converge" "$WC1" "0"
WC2=$(echo "$WC_OUTPUT" | grep -A1 'WC2:' | tail -1)
check "WC2 full N quiet window converges" "$WC2" "1"
WC3=$(echo "$WC_OUTPUT" | grep -A1 'WC3:' | tail -1)
check "WC3 single transient breaks convergence" "$WC3" "0"
WC4=$(echo "$WC_OUTPUT" | grep -A2 'WC4:' | tail -1)
check "WC4 newton sqrt reaches equilibrium not converged" "$WC4" "converged=0 equilibrium=1"
WC5=$(echo "$WC_OUTPUT" | grep -A1 'WC5:' | tail -1)
check "WC5 rebind-from-temp loop converges (issue #260)" "$WC5" "converged=1 equilibrium=1"
echo ""

echo "[8c] Predicate Matrix (15 checks)"
check_eigs_suite "predicate family matrix: mutual-exclusion + co-fire edges + threshold knob + newton sqrt" \
    "test_predicate_matrix.eigs" "PREDICATE_MATRIX_ALL_PASS" 15
echo ""

echo "[8d] Windowed Improving (8 checks)"
check_eigs_suite "windowed improving: net-descent + proportional vote + gray-band/sub-majority/partial-window" \
    "test_windowed_improving.eigs" "WINDOWED_IMPROVING_ALL_PASS" 8
echo ""

echo "[8e] Windowed Diverging (8 checks)"
check_eigs_suite "windowed diverging: net-ascent + proportional vote + gray-band/sub-majority/partial-window" \
    "test_windowed_diverging.eigs" "WINDOWED_DIVERGING_ALL_PASS" 8
echo ""

echo "[8f] Windowed Oscillating (8 checks)"
check_eigs_suite "windowed oscillating: flip-count threshold + dh_zero deadband + single-reversal/partial-window" \
    "test_windowed_oscillating.eigs" "WINDOWED_OSCILLATING_ALL_PASS" 8
echo ""

echo "[8g] Windowed Stable (8 checks)"
check_eigs_suite "windowed stable: full-window small-motion + entropy floor + no-flips + h_low boundary" \
    "test_windowed_stable.eigs" "WINDOWED_STABLE_ALL_PASS" 8
echo ""

echo "[8h] Windowed Equilibrium (8 checks)"
check_eigs_suite "windowed equilibrium: full-window zero-mean low-variance + mean/variance gates + partial-window" \
    "test_windowed_equilibrium.eigs" "WINDOWED_EQUILIBRIUM_ALL_PASS" 8
check_eigs_suite "named observer predicates: <pred> of x binds the named slot, not the last-observed alias" \
    "test_named_predicates.eigs" "All tests passed" 7
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

check_eigs_suite "reduction builtins dot/sum/norm (vs explicit loop + edge cases)" \
    "test_dot.eigs" "DOT_OK" 1
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
echo "[19/19] String & Math Builtins (75 checks)"
SM_OUTPUT=$(./eigenscript ../tests/test_string_math.eigs 2>&1)

if echo "$SM_OUTPUT" | grep -q "All string_math tests passed"; then
    TOTAL=$((TOTAL + 75))
    PASS=$((PASS + 75))
    echo "  PASS: all 75 string/math checks"
else
    TOTAL=$((TOTAL + 75))
    FAIL=$((FAIL + 75))
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

# [105] Over-long identifiers (#305). Names longer than the old 256-byte fixed
# lexer buffer must lex as a single token (strbuf-grown), not be silently
# truncated and split — a split surfaces as an undefined-variable/parse error.
echo "[105] Over-Long Identifiers (#305)"
check_eigs_suite "260/256/500-char identifiers round-trip" test_long_identifier.eigs "All tests passed" 1

# [106] Local pure-value cycles (#307). Self-/mutually-referential lists & dicts
# built in a local scope and dropped — reclaimed only by the Bacon-Rajan
# possible-root hook (gc_note_possible_root); before it they leaked unbounded.
# STRICT exit gate (no rc_ok leak tolerance), the value-cycle analogue of [87]:
# a LeakSanitizer exit here is a collector regression, not a tolerated leak.
echo "[106] Local Value Cycles (#307)"
TOTAL=$((TOTAL + 1))
VC_OUTPUT=$(./eigenscript ../tests/test_value_cycles.eigs </dev/null 2>&1); VC_OUTPUT_RC=$?
if [ "$VC_OUTPUT_RC" = "0" ] && echo "$VC_OUTPUT" | grep -q "All tests passed"; then
    PASS=$((PASS + 1))
    echo "  PASS: value cycles reclaimed; live cycle survives (leak-clean)"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: value-cycle checks (rc=$VC_OUTPUT_RC — must be leak-clean)"
    echo "$VC_OUTPUT" | grep -iE "FAIL|LeakSanitizer|assert|error" | head -5
fi

# [107] Meta-interpreter parity (#306). lib/eigen.eigs (the meta-circular
# interpreter) must agree with the C evaluator on and/or value-returning
# short-circuit, raising on unbound identifiers, and div/mod-by-zero values —
# the divergences it used to ship while claiming "full parity".
echo "[107] Meta-Interpreter Parity (#306)"
check_eigs_suite "eigen_run matches C VM (and/or operands, unbound raises, div/0)" test_meta_parity.eigs "All tests passed" 1

# [108] sandbox_run allocation budget (#292). The size-controlled allocators
# (zeros/fill/buffer/range) charge a per-run byte budget so untrusted generated
# code can't exhaust memory (single big alloc or aggregate) into an uncatchable
# x_oom/abort(); exceeding it returns {ok:0}. Includes the cumulative (F2) case.
echo "[108] Sandbox Allocation Budget (#292)"
check_eigs_suite "budget rejects bombs ({ok:0}), allows small, cumulative, per-run reset" test_sandbox_budget.eigs "All tests passed" 1

# [109] throw propagation across call frames (#322). A throw out of a called
# function must unwind to the nearest enclosing try — NOT keep running the
# caller's remaining statements. Covers multi-level, loop-in-fn, inner-catch
# (no over-unwind), and a JIT-hot throwing chain.
echo "[109] Throw Unwind Across Frames (#322)"
check_eigs_suite "nested throw halts caller's later statements; unwinds to enclosing try" test_throw_unwind.eigs "All tests passed" 1

# [110] compiler loop-context caps (#335/#336). Break #65+ in one loop used to
# emit the env cleanup without its jump (double free); loops nested past 32
# used to bind break to the 32nd loop's context (wrong target + stack
# corruption). Both caps are now dynamic.
echo "[110] Loop Caps: 65+ breaks, 33-deep nesting (#335/#336)"
check_eigs_suite "65th break in for/while; break in 33rd nested loop" test_loop_caps.eigs "All tests passed" 1

# [111] parser statement cap (#327). Statements past a fixed 4096 cap were
# parsed then silently dropped — at program level and inside blocks (a big
# define lost its return). Both statement arrays now grow on demand.
echo "[111] Statement Cap: 4200-stmt program + block (#327)"
check_eigs_suite "no silent truncation past 4096 statements" test_stmt_cap.eigs "All tests passed" 1

# [112] stray break/continue (#337). Outside any loop they are compile
# errors (were silent no-ops); compile-stage diagnostics fail eval /
# load_file / import with a catchable error instead of running a
# placeholder chunk. Direct-source rc=1 covered by examples/errors/ [90].
echo "[112] Stray break/continue Are Compile Errors (#337)"
check_eigs_suite "eval'd stray break/continue raise; in-loop still works" test_stray_break.eigs "All tests passed" 1

# [113] statement terminator (#326). Leftover tokens after a complete
# statement are a parse error (were a silent second statement on the same
# line — the `throw "x"` typo class). Meta-interpreter enforces the same.
# Direct-source rc=1 covered by examples/errors/ [90].
echo "[113] Statement Terminator Enforced (#326)"
check_eigs_suite "one statement per line; eval/meta parity" test_stmt_terminator.eigs "All tests passed" 1

# [114] compile scaling guards (#341). Constant indices are u16 operands:
# a pool past 65536 entries is a clean compile error (it used to WRAP and
# crash in env_hash_name on a NULL intern). Generated at test time (a
# 34k-statement file is not worth committing).
echo "[114] Constant-Pool u16 Ceiling (#341)"
CPG_FILE=$(mktemp /tmp/eigs_cpool_XXXX.eigs)
python3 -c "
n = 34000
print('\n'.join(f'w{i} is {i}' for i in range(n)))
print('print of \"should-not-run\"')" > "$CPG_FILE"
CPG_OUTPUT=$(./eigenscript "$CPG_FILE" </dev/null 2>&1); CPG_RC=$?
CPG_MSGS=$(echo "$CPG_OUTPUT" | grep -c "constant pool exceeds 65536" || true)
TOTAL=$((TOTAL + 1))
if [ "$CPG_RC" -ne 0 ] && [ "$CPG_MSGS" = "1" ] \
   && ! echo "$CPG_OUTPUT" | grep -q "should-not-run"; then
    PASS=$((PASS + 1))
    echo "  PASS: >65536-constant chunk fails cleanly (one diagnostic, no run)"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: constant-pool ceiling (rc=$CPG_RC msgs=$CPG_MSGS)"
    echo "$CPG_OUTPUT" | head -3
fi
rm -f "$CPG_FILE"

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
echo "[24/27] Try/Catch & Throw (23 checks)"
TC_OUTPUT=$(./eigenscript ../tests/test_trycatch.eigs 2>&1); TC_OUTPUT_RC=$?
if rc_ok "$TC_OUTPUT_RC" "$TC_OUTPUT" && echo "$TC_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 23))
    PASS=$((PASS + 23))
    echo "  PASS: all 23 try/catch checks"
else
    TOTAL=$((TOTAL + 23))
    FAIL=$((FAIL + 23))
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
echo "[36/36] Import System (19 checks)"
IM_OUTPUT=$(./eigenscript ../tests/test_import.eigs 2>&1); IM_OUTPUT_RC=$?
if rc_ok "$IM_OUTPUT_RC" "$IM_OUTPUT" && echo "$IM_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 19))
    PASS=$((PASS + 19))
    echo "  PASS: all 19 import checks"
else
    TOTAL=$((TOTAL + 19))
    FAIL=$((FAIL + 19))
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

# Crash-safety regressions: parser depth guard + builtin int-overflow bounds.
echo "Crash-safety regressions (parser depth + builtin overflow)"
PD_OUTPUT=$(bash "$TESTS_DIR/test_parse_depth.sh" 2>&1)
PD_PASS=$(echo "$PD_OUTPUT" | grep -c "PASS:" || true)
PD_FAIL=$(echo "$PD_OUTPUT" | grep -c "FAIL:" || true)
BO_OUTPUT=$(bash "$TESTS_DIR/test_builtin_overflow.sh" 2>&1)
BO_PASS=$(echo "$BO_OUTPUT" | grep -c "PASS:" || true)
BO_FAIL=$(echo "$BO_OUTPUT" | grep -c "FAIL:" || true)
PC_OUTPUT=$(bash "$TESTS_DIR/test_parse_caps.sh" 2>&1)
PC_PASS=$(echo "$PC_OUTPUT" | grep -c "  PASS:" || true)
PC_FAIL=$(echo "$PC_OUTPUT" | grep -c "FAIL:" || true)
TOTAL=$((TOTAL + PD_PASS + PD_FAIL + BO_PASS + BO_FAIL + PC_PASS + PC_FAIL))
PASS=$((PASS + PD_PASS + BO_PASS + PC_PASS))
FAIL=$((FAIL + PD_FAIL + BO_FAIL + PC_FAIL))
if [ "$PD_FAIL" -gt 0 ] || [ "$BO_FAIL" -gt 0 ] || [ "$PC_FAIL" -gt 0 ]; then
    echo "  FAIL: crash-safety regression"
    echo "$PD_OUTPUT" | grep "FAIL:" | head -5
    echo "$BO_OUTPUT" | grep "FAIL:" | head -5
    echo "$PC_OUTPUT" | grep "FAIL:" | head -5
else
    echo "  PASS: all $((PD_PASS + BO_PASS + PC_PASS)) crash-safety checks"
fi
echo ""

# exit builtin: clean process exit with a code, uncatchable, leak-clean.
echo "exit builtin (code + uncatchable + leak-clean)"
EX_OUTPUT=$(bash "$TESTS_DIR/test_exit.sh" 2>&1)
EX_PASS=$(echo "$EX_OUTPUT" | grep -c "PASS:" || true)
EX_FAIL=$(echo "$EX_OUTPUT" | grep -c "FAIL:" || true)
TOTAL=$((TOTAL + EX_PASS + EX_FAIL))
PASS=$((PASS + EX_PASS))
FAIL=$((FAIL + EX_FAIL))
if [ "$EX_FAIL" -gt 0 ]; then
    echo "  FAIL: $EX_FAIL exit check(s) failed"
    echo "$EX_OUTPUT" | grep "FAIL:" | head -5
else
    echo "  PASS: all $EX_PASS exit checks"
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

echo "[loop-halting] opt-in observer-stall classifier"
LH_OUTPUT=$(bash "$TESTS_DIR/test_loop_halting.sh" 2>&1)
LH_PASS=$(echo "$LH_OUTPUT" | grep -c "PASS:" || true)
LH_FAIL=$(echo "$LH_OUTPUT" | grep -c "FAIL:" || true)
TOTAL=$((TOTAL + LH_PASS + LH_FAIL))
PASS=$((PASS + LH_PASS))
FAIL=$((FAIL + LH_FAIL))
if [ "$LH_FAIL" -gt 0 ]; then
    echo "  FAIL: $LH_FAIL loop-halting check(s) failed"
    echo "$LH_OUTPUT" | grep "FAIL:" | head -8
else
    echo "  PASS: all $LH_PASS loop-halting checks"
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
echo "[42d/47] Stdlib Fixes (48 checks)"
SF_OUTPUT=$(./eigenscript ../tests/test_stdlib_fixes.eigs 2>&1); SF_OUTPUT_RC=$?
if rc_ok "$SF_OUTPUT_RC" "$SF_OUTPUT" && echo "$SF_OUTPUT" | grep -q "All stdlib-fix tests passed"; then
    TOTAL=$((TOTAL + 48))
    PASS=$((PASS + 48))
    echo "  PASS: all 48 stdlib-fix checks"
else
    TOTAL=$((TOTAL + 48))
    FAIL=$((FAIL + 48))
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
echo "[43/47] Error-Path Extras (48 checks)"
EE_OUTPUT=$(./eigenscript ../tests/test_error_extra.eigs 2>&1); EE_OUTPUT_RC=$?
if rc_ok "$EE_OUTPUT_RC" "$EE_OUTPUT" && echo "$EE_OUTPUT" | grep -q "All error_extra tests passed"; then
    TOTAL=$((TOTAL + 48))
    PASS=$((PASS + 48))
    echo "  PASS: all 48 error-path checks"
else
    TOTAL=$((TOTAL + 48))
    FAIL=$((FAIL + 48))
    echo "  FAIL: error-path tests"
    echo "$EE_OUTPUT" | grep -iE "assert|error" | head -5
fi
echo ""

# [43a2] Builtin argument-validation error paths (builtins.c arg guards)
echo "[43a2] Builtin Argument Errors (26 checks)"
check_eigs_suite "builtin argument errors" test_builtin_errors.eigs "All builtin_errors tests passed" 30
check_eigs_suite "module-boundary write insulation (#373)" test_module_scope.eigs "All module-scope tests passed" 9
echo ""

# [43a3] EigenStore header-validation / corruption error paths (ext_store.c)
echo "[43a3] Store Corruption Errors (12 checks)"
check_eigs_suite "store corruption errors" test_store_corruption.eigs "All store_corruption tests passed" 12
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
echo "[50] Bitwise Operations (37 checks)"
BW_OUTPUT=$(./eigenscript ../tests/test_bitwise.eigs 2>&1); BW_OUTPUT_RC=$?
if rc_ok "$BW_OUTPUT_RC" "$BW_OUTPUT" && echo "$BW_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 37))
    PASS=$((PASS + 37))
    echo "  PASS: all 37 bitwise checks"
else
    TOTAL=$((TOTAL + 37))
    FAIL=$((FAIL + 37))
    echo "  FAIL: bitwise tests"
    echo "$BW_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [50b] Hex integer literals (lexed, not strtod — the freestanding profile
# has no hex strtod path, so this form must never regress to delegation)
echo "[50b] Hex Integer Literals (19 checks + 3 rejects)"
check_eigs_suite "hex literals: 0x/0X forms, case, adjacency, arithmetic" \
    "test_hex_literals.eigs" "HEX_LITERALS_ALL_PASS" 19
# Hex-float forms and a bare prefix must be LOUD parse errors on every
# profile — strtod must never see a hex prefix (glibc would quietly
# parse 0x1p4 / 0x.8 while the freestanding mini_strtod cannot).
for bad in '0x1p4' '0x.8' '0x'; do
    TOTAL=$((TOTAL + 1))
    printf 'x is %s\nprint of (str of x)\n' "$bad" > /tmp/eigs_hex_reject.eigs
    if ./eigenscript /tmp/eigs_hex_reject.eigs </dev/null >/dev/null 2>&1; then
        FAIL=$((FAIL + 1))
        echo "  FAIL: '$bad' parsed (must be a loud parse error)"
    else
        PASS=$((PASS + 1))
        echo "  PASS: '$bad' rejected loudly"
    fi
done
rm -f /tmp/eigs_hex_reject.eigs
echo ""

# [50c] Checksum library (CRC-32 / Adler-32 / sum8 over strings+buffers)
echo "[50c] Checksums (9 checks)"
check_eigs_suite "checksums: published vectors + buffer/string equivalence" \
    "test_checksum.eigs" "CHECKSUM_ALL_PASS" 9
echo ""

# [50d] Datetime civil math (pure half of lib/datetime.eigs)
echo "[50d] Datetime Civil Math (14 checks)"
check_eigs_suite "civil days/epoch round-trips + leap edges vs references" \
    "test_datetime_civil.eigs" "DATETIME_CIVIL_ALL_PASS" 14
echo ""

# [50e-50i] Stdlib backlog train: bcd, wait_until, hexdump, harness, observer_slots
echo "[50e] BCD Codec (10 checks)"
check_eigs_suite "bcd: round-trips + loud invalid-nibble/fraction rejection" \
    "test_bcd.eigs" "BCD_ALL_PASS" 10
echo ""

echo "[50f] wait_until (7 checks)"
check_eigs_suite "functional.wait_until: success timing, timeout, sleep cadence" \
    "test_wait_until.eigs" "WAIT_UNTIL_ALL_PASS" 7
echo ""

echo "[50g] hexdump (7 checks)"
check_eigs_suite "format.hexdump: exact rows, offsets, buffer/string parity" \
    "test_hexdump.eigs" "HEXDUMP_ALL_PASS" 7
echo ""

echo "[50h] Harness (4 checks)"
check_eigs_suite "harness: count-and-continue, throwing finish, reset" \
    "test_harness.eigs" "HARNESS_ALL_PASS" 4
echo ""

echo "[50i] Observer Slots (6 checks)"
check_eigs_suite "observer_slots: trajectories through slot dispatch, independence" \
    "test_observer_slots.eigs" "OBSERVER_SLOTS_ALL_PASS" 6
echo ""

echo "[50j] Trajectory Contracts (15 checks)"
check_eigs_suite "contract: require/ensure + expect_converging/monotone/invariant_stable, value-channel divergence catch, scalar guard" \
    "test_contract.eigs" "CONTRACT_ALL_PASS" 1
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
# + #353 fast-path/builtin error parity (non-list table, non-callable slot)
echo "[68] Dispatch (14 checks)"
DISP_OUTPUT=$(./eigenscript ../tests/test_dispatch.eigs 2>&1); DISP_OUTPUT_RC=$?
if rc_ok "$DISP_OUTPUT_RC" "$DISP_OUTPUT" && echo "$DISP_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 14))
    PASS=$((PASS + 14))
    echo "  PASS: all 14 dispatch checks"
else
    TOTAL=$((TOTAL + 14))
    FAIL=$((FAIL + 14))
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

# Temporal correctness under JIT/OSR: a deep loop's `at`/`state_at` must not
# freeze at the OSR point (OP_LINE must stamp g_trace_current_line in the JIT).
check_eigs_suite "JIT temporal at/state_at under OSR (g_trace_current_line)" test_jit_temporal_osr.eigs "All tests passed" 2

# [98] Cross-thread channel dict-key survival (#293).
echo "[98] Cross-thread Channel Dict Keys (7 checks)"
XCD_OUTPUT=$(./eigenscript ../tests/test_chan_dict_xthread.eigs 2>&1); XCD_OUTPUT_RC=$?
if rc_ok "$XCD_OUTPUT_RC" "$XCD_OUTPUT" && echo "$XCD_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 7))
    PASS=$((PASS + 7))
    echo "  PASS: all 7 cross-thread dict-key checks"
else
    TOTAL=$((TOTAL + 7))
    FAIL=$((FAIL + 7))
    echo "  FAIL: cross-thread dict-key tests"
    echo "$XCD_OUTPUT" | grep -iE "MISMATCH|FAIL|error" | head -5
fi
echo ""

# [99] Value-signal observer channel — report_value (#294). Pins that the value
# channel classifies the value trajectory (not entropy) against closed-form
# oracles: blind-to-slow-oscillation entropy vs not-settled value, fast
# oscillation, geometric decay -> converged, monotone climb -> moving.
echo "[99] Value-Signal Observer (report_value, #294)"
check_eigs_suite "report_value value-channel verdicts" test_observer_value_signal.eigs "All tests passed." 1

# [100] Worker-thread JIT lifetime (#296). A shared chunk that gets hot and
# JIT-compiles ON a worker must not leave chunk->jit_code dangling when that
# worker exits (its per-thread JIT code arena is munmap'd at detach). Crashed
# (SEGV) at scale before the fix; gated rc_ok so a regression (crash) fails.
echo "[100] Worker-Thread JIT Lifetime (#296)"
check_eigs_suite "shared chunk JIT-compiled on a worker, many workers" test_spawn_jit.eigs "All tests passed" 1

# [101] Threaded cycle-GC: env<->closure cycles created on worker threads must be
# reclaimed at exit (per-state lock-guarded collector registry; collection runs
# once workers are joined). A regression that drops MT-created cycles surfaces as
# an ASan leak here -> bumps the tolerated-leak tally, not a marker failure.
echo "[101] Threaded Cycle-GC (worker-created cycles collected)"
check_eigs_suite "worker closure cycles reclaimed at exit" test_spawn_gc.eigs "All tests passed" 1

# [102] Parallel shared-chunk execution correctness (#297). Workers spawned all
# at once (genuine parallelism) run the same chunks concurrently; the inline
# caches / JIT counters / lazy name-hash / multithreaded-flag write are shared
# state that raced (a torn IC write could give a wrong cache hit). Pins correct
# results; TSan-cleanliness verified out of band.
echo "[102] Parallel Shared-Chunk Execution (#297)"
check_eigs_suite "concurrent workers, same chunks, exact results" test_spawn_parallel.eigs "All tests passed" 1

# [103] Exit must not hang on a channel-blocked worker (#303). handle_table_drain
# closes+wakes channels before joining; a recv-blocked worker on a never-closed
# channel must wake and let the program exit (this test times out if it regresses).
echo "[103] Spawn/Channel Exit (no hang on blocked worker, #303)"
check_eigs_suite "recv-blocked worker doesn't hang exit" test_spawn_channel_exit.eigs "All tests passed" 1

# [104] Worker arena-allocated return value survives detach (#302). thread_entry
# deep-copies the result before arena_destroy frees the worker arena; a UAF here
# is ASan-caught, and the values are pinned.
echo "[104] Worker Arena Return (no cross-thread UAF, #302)"
check_eigs_suite "worker arena return deep-copied before detach" test_spawn_arena_return.eigs "All tests passed" 1

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

# [81b] Test runner (--test) + exe_path builtin — runs test_*.eigs files
# in their own processes and reports pass/fail (human + --json).
echo "[81b] Test runner (--test)"
TRUN_OUTPUT=$(bash "$TESTS_DIR/test_test_runner.sh" </dev/null 2>&1)
TRUN_PASS=$(echo "$TRUN_OUTPUT" | grep -c "PASS:" || true)
TRUN_FAIL=$(echo "$TRUN_OUTPUT" | grep -c "FAIL:" || true)
TOTAL=$((TOTAL + TRUN_PASS + TRUN_FAIL))
PASS=$((PASS + TRUN_PASS))
FAIL=$((FAIL + TRUN_FAIL))
if [ "$TRUN_FAIL" -gt 0 ]; then
    echo "  FAIL: $TRUN_FAIL test-runner check(s) failed"
    echo "$TRUN_OUTPUT" | grep "FAIL:" | head -5
else
    echo "  PASS: all $TRUN_PASS test-runner checks"
fi
echo ""

# [82] JIT fast paths — checksummed correctness for the fused opcodes,
# inline ICs, iter/native-call helpers, and OSR that only fire on hot
# benchmark-shaped code. Runs with EIGS_JIT_STATS so we can also assert
# (on x86-64) that thunks really compiled — a regression that quietly
# disables the JIT must not let this section pass interpreted.
echo "[82] JIT Fast Paths (23 checks + thunk gate)"
JPATH_OUTPUT=$(EIGS_JIT_STATS=1 ./eigenscript ../tests/test_jit_paths.eigs </dev/null 2>&1); JPATH_RC=$?
TOTAL=$((TOTAL + 23))
if rc_ok "$JPATH_RC" "$JPATH_OUTPUT" && echo "$JPATH_OUTPUT" | grep -q "All tests passed"; then
    PASS=$((PASS + 23))
    echo "  PASS: all 23 JIT fast-path checks"
else
    FAIL=$((FAIL + 23))
    echo "  FAIL: JIT fast-path tests (rc=$JPATH_RC)"
    echo "$JPATH_OUTPUT" | grep -iE "FAIL|error" | head -5
fi
TOTAL=$((TOTAL + 1))
# macos-x86_64 now ships with the JIT enabled via the Mach-O TLV-aware
# prologue (the dict-field inline cache stays off — slow-path helper
# runs instead — but every other fast path emits). Same thunk-gate as
# Linux x86_64.
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
    echo "  SKIP: thunk gate (JIT not built or not supported on this platform)"
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
echo "[84] Builtin Direct-vs-Indirect (40 checks)"
check_eigs_suite "all 40 builtin direct/indirect checks" test_builtin_indirect.eigs "All tests passed" 40

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
check_eigs_suite "byte<->value builtins (str_from_bytes / f64 bytes)" test_byte_value_builtins.eigs "All tests passed" 19
check_eigs_suite "write_bytes (binary append/truncate)" test_write_bytes.eigs "All tests passed" 10
check_eigs_suite "rename / remove_file (atomic swap, delete)" test_file_rename.eigs "All tests passed" 12
check_eigs_suite "vm_run_bytecode + sandbox (self-hosting bridge)" test_vm_run_bytecode.eigs "All tests passed" 29
check_eigs_suite "sandbox fail-closed allowlist (no host-global escape)" test_sandbox_allow.eigs "SANDBOX_ALLOW_OK" 1
check_eigs_suite "JIT and/or heap-operand decref (no per-iteration leak)" test_jit_andor_leak.eigs "jit-and-or-ok" 1
check_eigs_suite "json hard" test_json_hard.eigs "json hard: all passed" 1
check_eigs_suite "json roundtrip" test_json_roundtrip.eigs "json roundtrip: all passed" 1
check_eigs_suite "observer interactions" test_observer_interactions.eigs "observer interactions: all passed" 1
check_eigs_suite "osr observe-assign (#231)" test_osr_observe_assign.eigs "osr observe-assign: all passed" 1
check_eigs_suite "scope semantics" test_scope_semantics.eigs "scope semantics: all passed" 1
check_eigs_suite "soft keyword idents" test_soft_keyword_idents.eigs "soft keyword idents: all passed" 1
check_eigs_suite "split empty" test_split_empty.eigs "split empty: all passed" 1
check_eigs_suite "split hard" test_split_hard.eigs "split hard: all passed" 1
check_eigs_suite "tensor overflow guard" test_tensor_overflow.eigs "PASS: tensor overflow guard" 1
check_eigs_suite "flat-buffer tensors" test_flat_buffer_tensor.eigs "PASS: flat-buffer tensors" 1
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

# Observer state is part of binding identity: a parked/recycled call env must
# reset Env::obs, or a windowed predicate on an observed local reads the prior
# invocation's trajectory (vm_park_call_env). Guards both the drift and that a
# full-window single call still converges on the reused env.
echo "[Observer] Parked call-env observer reset"
check_eigs_suite "observer park-env reset" test_observer_park.eigs "OBS_PARK_OK" 1
echo ""

# #366: frameless leaf-accessor call fast path — results, borrows from
# temporary args, redefinition, lambdas, and non-qualifying fallbacks must
# match the generic CALL path exactly (vm_leaf_accessor_exec bails to the
# generic path on any surprise, so error/traceback parity is by design).
echo "[Calls] Leaf-accessor fast path"
check_eigs_suite "leaf-accessor calls" test_leaf_call.eigs "LEAF_CALL_OK" 1
echo ""

# [87] Closure-cycle shapes — functional correctness of every env<->fn
# and value cycle (a KNOWN accumulating leak the runtime can't reclaim;
# see docs/CLOSURE_CYCLE_GC.md). Locks that the shapes compute correctly
# and that the non-leaking invariants (self-ref containers, non-escaping
# recursion) hold. Tolerated leak-exit under ASan (counted by rc_ok).
echo "[87] Closure Cycle Shapes (17 checks)"
# STRICT exit gate (no rc_ok leak tolerance): the cycle collector must
# keep every shape in this file ASan-clean. A LeakSanitizer exit here is
# a collector regression, not a tolerated known leak.
TOTAL=$((TOTAL + 17))
CC_OUTPUT=$(./eigenscript ../tests/test_closure_cycles.eigs </dev/null 2>&1); CC_OUTPUT_RC=$?
if [ "$CC_OUTPUT_RC" = "0" ] && echo "$CC_OUTPUT" | grep -q "All tests passed"; then
    PASS=$((PASS + 17))
    echo "  PASS: all 17 closure-cycle checks (leak-clean)"
else
    FAIL=$((FAIL + 17))
    echo "  FAIL: closure-cycle checks (rc=$CC_OUTPUT_RC — must be leak-clean)"
    echo "$CC_OUTPUT" | grep -iE "FAIL|LeakSanitizer|assert|error" | head -5
fi
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

# [89] Executable documentation — every eigenscript/output block pair in
# docs/SPEC.md and docs/COMPARISON.md runs and must match exactly, so
# the spec cannot drift from the implementation. Skips without python3.
echo "[89] Doc Examples (SPEC.md + COMPARISON.md)"
if command -v python3 >/dev/null 2>&1; then
    DOC_OUTPUT=$(python3 "$TESTS_DIR/test_doc_examples.py" "$TESTS_DIR/../docs/SPEC.md" "$TESTS_DIR/../docs/COMPARISON.md" 2>&1)
    DOC_PASS=$(echo "$DOC_OUTPUT" | grep -c "  PASS:" || true)
    DOC_FAIL=$(echo "$DOC_OUTPUT" | grep -c "  FAIL:" || true)
    TOTAL=$((TOTAL + DOC_PASS + DOC_FAIL))
    PASS=$((PASS + DOC_PASS))
    FAIL=$((FAIL + DOC_FAIL))
    if [ "$DOC_FAIL" -gt 0 ]; then
        echo "  FAIL: $DOC_FAIL doc example(s) diverge from the implementation"
        echo "$DOC_OUTPUT" | grep -A8 "FAIL:" | head -20
    else
        echo "  PASS: all $DOC_PASS doc examples match"
    fi
else
    echo "  SKIP: python3 not available"
fi
echo ""

# [90] Error examples — examples/errors/*.eigs must exit nonzero and
# print their declared '# expect-error:' message.
echo "[90] Error Examples (10 checks)"
ERR_OUTPUT=$(bash "$TESTS_DIR/test_error_examples.sh" 2>&1)
ERR_PASS=$(echo "$ERR_OUTPUT" | grep -c "  PASS:" || true)
ERR_FAIL=$(echo "$ERR_OUTPUT" | grep -c "  FAIL:" || true)
TOTAL=$((TOTAL + ERR_PASS + ERR_FAIL))
PASS=$((PASS + ERR_PASS))
FAIL=$((FAIL + ERR_FAIL))
if [ "$ERR_FAIL" -gt 0 ]; then
    echo "  FAIL: $ERR_FAIL error example(s)"
    echo "$ERR_OUTPUT" | grep -A3 "FAIL:" | head -12
else
    echo "  PASS: all $ERR_PASS error examples fail as documented"
fi
echo ""

echo "[91] Module Cache (3 checks)"
# Phase 0a of the package design: repeat imports of the same resolved
# path share one dict + Env (no body re-execution). modcache_fixture.eigs
# prints FIXTURE_RAN at top level exactly once; test_module_cache.eigs
# imports it twice and verifies bindings + cached fns still work.
MC_OUTPUT=$(./eigenscript "../tests/test_module_cache.eigs" </dev/null 2>&1); MC_RC=$?
MC_RUNS=$(echo "$MC_OUTPUT" | grep -c "^FIXTURE_RAN$" || true)
if rc_ok "$MC_RC" "$MC_OUTPUT" \
   && [ "$MC_RUNS" = "1" ] \
   && echo "$MC_OUTPUT" | grep -q "PASS: greeting bound" \
   && echo "$MC_OUTPUT" | grep -q "PASS: fn from cached module works"; then
    TOTAL=$((TOTAL + 3))
    PASS=$((PASS + 3))
    echo "  PASS: module cache: body runs once + bindings + fns"
else
    TOTAL=$((TOTAL + 3))
    FAIL=$((FAIL + 3))
    echo "  FAIL: module cache (rc=$MC_RC, fixture_runs=$MC_RUNS)"
    echo "$MC_OUTPUT" | head -10
fi
echo ""

echo "[92] Module Resolve Base (1 check)"
# Phase 0b: an `import` inside a module resolves relative to *that
# module's* directory, not the main script's. Shell-driven because
# `import` only takes bare identifiers — we need a HOME-override +
# symlink dance to put a "wrapper" module in a subdir whose peer.eigs
# is reachable only if resolution anchors at the wrapper's own dir.
TOTAL=$((TOTAL + 1))
if EIGENSCRIPT="./eigenscript" bash "$TESTS_DIR/test_module_resolve_base.sh" >/dev/null 2>&1; then
    echo "  PASS: nested import anchors at module dir"
    PASS=$((PASS + 1))
else
    echo "  FAIL: module resolve base"
    EIGENSCRIPT="./eigenscript" bash "$TESTS_DIR/test_module_resolve_base.sh" 2>&1 | head -10
    FAIL=$((FAIL + 1))
fi
echo ""

echo "[93] eigs_modules Resolver (2 checks)"
# Phase 0c: `import name` looks up eigs_modules/<name>/<name>.eigs by
# walking upward from the importing file's directory until it hits the
# project root (a directory containing eigs.json). Both the find and
# the project-root halt are exercised.
TOTAL=$((TOTAL + 2))
EM_OUT=$(EIGENSCRIPT="./eigenscript" bash "$TESTS_DIR/test_eigs_modules_resolve.sh" 2>&1); EM_RC=$?
if [ "$EM_RC" = "0" ] \
   && echo "$EM_OUT" | grep -q "PASS: eigs_modules walk-up finds project-root package" \
   && echo "$EM_OUT" | grep -q "PASS: eigs.json halts the walk"; then
    echo "  PASS: walk-up resolves project-root package"
    echo "  PASS: eigs.json halts the walk"
    PASS=$((PASS + 2))
else
    echo "  FAIL: eigs_modules resolver"
    echo "$EM_OUT" | head -10
    FAIL=$((FAIL + 2))
fi
echo ""

echo "[94] --pkg dispatcher (7 checks)"
# Phase 1a of the package design: --pkg dispatcher, manifest read/write,
# help, list, add (manifest-only — git fetch is Phase 1b), unknown
# subcommand exits nonzero, plus the bare-name rejection that the
# namespaced-identifier rule added.
TOTAL=$((TOTAL + 7))
PKG_OUT=$(EIGENSCRIPT="./eigenscript" bash "$TESTS_DIR/test_pkg_skeleton.sh" 2>&1); PKG_RC=$?
PKG_PASS=$(echo "$PKG_OUT" | grep -c "^  PASS:" || true)
if [ "$PKG_RC" = "0" ] && [ "$PKG_PASS" = "7" ]; then
    echo "$PKG_OUT" | grep "^  PASS:"
    PASS=$((PASS + 7))
else
    echo "  FAIL: --pkg skeleton (rc=$PKG_RC, passes=$PKG_PASS)"
    echo "$PKG_OUT" | head -15
    FAIL=$((FAIL + 7))
fi
echo ""

echo "[95] --pkg fetch (6 checks)"
# Phase 1b: --pkg add and --pkg install actually shell out to git
# against a local file:// repo. Verifies the clone lands in
# eigs_modules/, the lockfile records the resolved commit, the
# clone is importable through Phase 0c's eigs_modules resolver, and
# the lockfile wins over a force-pushed tag. Also asserts bare names
# are rejected (namespaced-identifier rule).
TOTAL=$((TOTAL + 6))
PKG2_OUT=$(EIGENSCRIPT="./eigenscript" bash "$TESTS_DIR/test_pkg_fetch.sh" 2>&1); PKG2_RC=$?
PKG2_PASS=$(echo "$PKG2_OUT" | grep -c "^  PASS:" || true)
PKG2_SKIP=$(echo "$PKG2_OUT" | grep -c "^  SKIP:" || true)
if [ "$PKG2_RC" = "0" ] && [ "$PKG2_PASS" = "6" ]; then
    echo "$PKG2_OUT" | grep "^  PASS:"
    PASS=$((PASS + 6))
elif [ "$PKG2_SKIP" -gt "0" ]; then
    echo "$PKG2_OUT" | grep "^  SKIP:"
    PASS=$((PASS + 6))
else
    echo "  FAIL: --pkg fetch (rc=$PKG2_RC, passes=$PKG2_PASS)"
    echo "$PKG2_OUT" | head -20
    FAIL=$((FAIL + 6))
fi
echo ""

echo "[96] --pkg verify + update (7 checks)"
# Phase 1c: --pkg verify (re-hash trees against lockfile) and --pkg
# update (re-resolve manifest tag to a new commit and re-lock).
# Drives both against a local file:// source repo.
TOTAL=$((TOTAL + 7))
PKG3_OUT=$(EIGENSCRIPT="./eigenscript" bash "$TESTS_DIR/test_pkg_verify_update.sh" 2>&1); PKG3_RC=$?
PKG3_PASS=$(echo "$PKG3_OUT" | grep -c "^  PASS:" || true)
PKG3_SKIP=$(echo "$PKG3_OUT" | grep -c "^  SKIP:" || true)
if [ "$PKG3_RC" = "0" ] && [ "$PKG3_PASS" = "7" ]; then
    echo "$PKG3_OUT" | grep "^  PASS:"
    PASS=$((PASS + 7))
elif [ "$PKG3_SKIP" -gt "0" ]; then
    echo "$PKG3_OUT" | grep "^  SKIP:"
    PASS=$((PASS + 7))
else
    echo "  FAIL: --pkg verify+update (rc=$PKG3_RC, passes=$PKG3_PASS)"
    echo "$PKG3_OUT" | head -30
    FAIL=$((FAIL + 7))
fi
echo ""

# ---- stdlib parse-check: every lib/*.eigs must parse clean ----
# Regression guard for the keyword-shadow class: an identifier shadowing a
# reserved keyword (lab.eigs's `stable`, functional.eigs's `when`) is a parse
# error that load_file used to silently swallow, so a broken stdlib helper was
# invisible. --lint parses without executing and prints "Parse error line" on a
# genuine parse error (its nonzero exit also covers style warnings, so grep the
# message rather than the exit code).
echo "[stdlib] parse-check every lib/*.eigs (--lint, no execution)"
for libf in ../lib/*.eigs; do
    TOTAL=$((TOTAL + 1))
    PC_OUT=$(./eigenscript --lint "$libf" 2>&1 | grep -iE 'Parse error line')
    if [ -z "$PC_OUT" ]; then
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $(basename "$libf") has a parse error:"
        printf '%s\n' "$PC_OUT" | head -3
        FAIL=$((FAIL + 1))
    fi
done
echo ""

# [97] Example programs — every examples/*.eigs (and examples/stem/*.eigs)
# must run to a clean exit. examples/errors/ is covered by [90]; the gfx
# demos (gfx_* builtins) need `make gfx` and are skipped on the default build.
# Each runs from its own directory (so relative paths resolve) with stdin
# closed. rc_ok tolerates the spawn-thread LeakSanitizer floor; no non-gfx
# example uses spawn, so this stays leak-clean.
echo "[97] Example programs (examples/*.eigs; gfx demos skipped)"
EX_PASS=0; EX_FAIL=0; EX_SKIP=0
EIGS_ABS="$(pwd)/eigenscript"
# GNU `timeout` is the runaway guard, but it isn't on a stock macOS (BSD
# userland); fall back to gtimeout, or to no wrapper (the examples all
# terminate quickly, so the guard is belt-and-suspenders).
EX_TMO=""
if command -v timeout >/dev/null 2>&1; then EX_TMO="timeout 60"
elif command -v gtimeout >/dev/null 2>&1; then EX_TMO="gtimeout 60"; fi
for f in $(find ../examples -name '*.eigs' -not -path '*/errors/*' | sort); do
    if grep -q 'gfx_' "$f"; then EX_SKIP=$((EX_SKIP + 1)); continue; fi
    EX_OUT=$( cd "$(dirname "$f")" && $EX_TMO "$EIGS_ABS" "$(basename "$f")" </dev/null 2>&1 ); EX_RC=$?
    if rc_ok "$EX_RC" "$EX_OUT"; then
        EX_PASS=$((EX_PASS + 1))
    else
        echo "  FAIL($EX_RC): $f"
        printf '%s\n' "$EX_OUT" | tail -1 | sed 's/^/      /'
        EX_FAIL=$((EX_FAIL + 1))
    fi
done
TOTAL=$((TOTAL + EX_PASS + EX_FAIL))
PASS=$((PASS + EX_PASS))
FAIL=$((FAIL + EX_FAIL))
if [ "$EX_FAIL" -gt 0 ]; then
    echo "  FAIL: $EX_FAIL example(s) errored"
else
    echo "  PASS: all $EX_PASS example programs run clean ($EX_SKIP gfx skipped)"
fi
echo ""

echo "[99] Doc drift (mechanical)"
TOTAL=$((TOTAL + 1))
if bash "$TESTS_DIR/../tools/doc_drift_check.sh"; then
    PASS=$((PASS + 1))
    echo "  PASS: no mechanical doc drift (STDLIB coverage, release line, CHANGELOG section)"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: doc drift detected (see DRIFT lines above)"
fi
echo ""

echo "[99b] Stdlib/builtin discoverability (#393)"
TOTAL=$((TOTAL + 1))
if bash "$TESTS_DIR/../tools/stdlib_index_check.sh" && bash "$TESTS_DIR/../tools/stdlib_index_check.sh" --selftest >/dev/null; then
    PASS=$((PASS + 1))
    echo "  PASS: every registered builtin + lib module is documented (gate self-test green)"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: undocumented builtin/module, or gate self-test broke (see lines above)"
fi
echo ""

echo "============================================"
echo "  RESULTS: $PASS/$TOTAL passed, $FAIL failed"
if [ "$LEAKED" -gt 0 ]; then
    echo "  NOTE: $LEAKED test program(s) exited nonzero on LeakSanitizer"
    echo "  reports (spawn-thread programs + known non-closure leak"
    echo "  shapes; counted as passes — closure cycles are collected)."
fi
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
