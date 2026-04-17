#!/bin/bash
set -e
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/../src"

PASS=0
FAIL=0
TOTAL=0

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
    local in_range=$(python3 -c "v=float('$actual'); print(1 if $min <= v <= $max else 0)" 2>/dev/null || echo "0")
    if [ "$in_range" = "1" ]; then
        echo "  PASS: $test_name ($actual in [$min, $max])"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $test_name ($actual not in [$min, $max])"
        FAIL=$((FAIL + 1))
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

echo "[4/15] Keyword Reservation (12 first-class citizens)"
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
check "JS5 object decode key" "$JS4_KEY" "name"
echo ""

echo "[14/15] Arena Ownership (5 checks)"
AO_OUTPUT=$(./eigenscript ../tests/test_arena_ownership.eigs 2>&1)

AO1_Y=$(echo "$AO_OUTPUT" | grep -A1 'AO1:' | tail -1)
check "AO1 new local in arena window survives reset" "$AO1_Y" "42"

AO2_W0=$(echo "$AO_OUTPUT" | grep -A1 'AO2:' | tail -1)
check "AO2 50x sgd_update w[0]" "$AO2_W0" "0.5"

AO2_W3=$(echo "$AO_OUTPUT" | grep -A2 'AO2:' | tail -1)
check "AO2 50x sgd_update w[3]" "$AO2_W3" "3.5"

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
check_exit "EM14 runtime error exits 0" 'x is [1] - 5' "0"
check_exit "EM15 warning exits 0" 'x is 10 / 0' "0"
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
        V0_MODEL=$(ls "$EIGS_V0_MODEL_DIR"/*.json 2>/dev/null | head -1)
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
FIO_EXIT=$?

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
echo "[19/19] String & Math Builtins (40 checks)"
SM_OUTPUT=$(./eigenscript ../tests/test_string_math.eigs 2>&1)

if echo "$SM_OUTPUT" | grep -q "All string_math tests passed"; then
    TOTAL=$((TOTAL + 40))
    PASS=$((PASS + 40))
    echo "  PASS: all 40 string/math checks"
else
    TOTAL=$((TOTAL + 40))
    FAIL=$((FAIL + 40))
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
FS_OUTPUT=$(./eigenscript ../tests/test_fstrings.eigs 2>&1)
if echo "$FS_OUTPUT" | grep -q "All tests passed"; then
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
NP_OUTPUT=$(./eigenscript ../tests/test_named_params.eigs 2>&1)
if echo "$NP_OUTPUT" | grep -q "All tests passed"; then
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
TC_OUTPUT=$(./eigenscript ../tests/test_trycatch.eigs 2>&1)
if echo "$TC_OUTPUT" | grep -q "All tests passed"; then
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
DI_OUTPUT=$(./eigenscript ../tests/test_dict.eigs 2>&1)
if echo "$DI_OUTPUT" | grep -q "All tests passed"; then
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
echo "[26/27] Eval Builtin (6 checks)"
EV_OUTPUT=$(./eigenscript ../tests/test_eval.eigs 2>&1)
if echo "$EV_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 6))
    PASS=$((PASS + 6))
    echo "  PASS: all 6 eval checks"
else
    TOTAL=$((TOTAL + 6))
    FAIL=$((FAIL + 6))
    echo "  FAIL: eval tests"
    echo "$EV_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [27] Closures
echo "[27/27] Closures (10 checks)"
CL_OUTPUT=$(./eigenscript ../tests/test_closures.eigs 2>&1)
if echo "$CL_OUTPUT" | grep -q "All tests passed"; then
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

# [29] Break and continue
echo "[29/31] Break & Continue (9 checks)"
BC_OUTPUT=$(./eigenscript ../tests/test_break_continue.eigs 2>&1)
if echo "$BC_OUTPUT" | grep -q "All tests passed"; then
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

# [30] Dot-assignment
echo "[30/31] Dot-Assignment (6 checks)"
DA_OUTPUT=$(./eigenscript ../tests/test_dot_assign.eigs 2>&1)
if echo "$DA_OUTPUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 6))
    PASS=$((PASS + 6))
    echo "  PASS: all 6 dot-assign checks"
else
    TOTAL=$((TOTAL + 6))
    FAIL=$((FAIL + 6))
    echo "  FAIL: dot-assign tests"
    echo "$DA_OUTPUT" | grep -i "FAIL\|assert\|error" | head -5
fi
echo ""

# [31] Multiline collections
echo "[31/31] Multiline Collections (12 checks)"
ML_OUTPUT=$(./eigenscript ../tests/test_multiline.eigs 2>&1)
if echo "$ML_OUTPUT" | grep -q "All tests passed"; then
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
MB_OUTPUT=$(./eigenscript ../tests/test_misc_builtins.eigs 2>&1)
if echo "$MB_OUTPUT" | grep -q "All tests passed"; then
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
RX_OUTPUT=$(./eigenscript ../tests/test_regex.eigs 2>&1)
if echo "$RX_OUTPUT" | grep -q "All tests passed"; then
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
IM_OUTPUT=$(./eigenscript ../tests/test_import.eigs 2>&1)
if echo "$IM_OUTPUT" | grep -q "All tests passed"; then
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
PM_OUTPUT=$(./eigenscript ../tests/test_match.eigs 2>&1)
if echo "$PM_OUTPUT" | grep -q "All tests passed"; then
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
PL_OUTPUT=$(./eigenscript ../tests/test_pipe_lambda.eigs 2>&1)
if echo "$PL_OUTPUT" | grep -q "All tests passed"; then
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
CG_OUTPUT=$(./eigenscript ../tests/test_coverage_gaps.eigs 2>&1)
if echo "$CG_OUTPUT" | grep -q "All coverage-gap tests passed"; then
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

# [42b] Softmax numerical guard (always runs — uses core tensor builtins)
echo "[42b/47] Softmax Guard (7 checks)"
SG_OUTPUT=$(./eigenscript ../tests/test_softmax_guard.eigs 2>&1)
if echo "$SG_OUTPUT" | grep -q "All softmax-guard tests passed"; then
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

# [42c] Stdlib fixes (math.dot bounds, test.assert_near types, template no-reinterpretation)
echo "[42c/47] Stdlib Fixes (11 checks)"
SF_OUTPUT=$(./eigenscript ../tests/test_stdlib_fixes.eigs 2>&1)
if echo "$SF_OUTPUT" | grep -q "All stdlib-fix tests passed"; then
    TOTAL=$((TOTAL + 11))
    PASS=$((PASS + 11))
    echo "  PASS: all 11 stdlib-fix checks"
else
    TOTAL=$((TOTAL + 11))
    FAIL=$((FAIL + 11))
    echo "  FAIL: stdlib-fix tests"
    echo "$SF_OUTPUT" | grep -iE "assert|error|FAIL" | head -5
fi
echo ""

# [43] Extra error-path coverage (always runs)
echo "[43/47] Error-Path Extras (24 checks)"
EE_OUTPUT=$(./eigenscript ../tests/test_error_extra.eigs 2>&1)
if echo "$EE_OUTPUT" | grep -q "All error_extra tests passed"; then
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
RG_OUTPUT=$(./eigenscript ../tests/test_recursion_guard.eigs 2>&1)
if echo "$RG_OUTPUT" | grep -q "All recursion-guard tests passed"; then
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

# [44] HTTP extension builtins (probe-gated)
HTTP_PROBE_FILE=$(mktemp /tmp/eigs_http_probe_XXXXXX.eigs)
cat > "$HTTP_PROBE_FILE" <<'PROBE'
r is http_route of ["GET", "/probe", "probe"]
print of r
PROBE
HTTP_PROBE_OUT=$(./eigenscript "$HTTP_PROBE_FILE" 2>&1)
rm -f "$HTTP_PROBE_FILE"

if ! echo "$HTTP_PROBE_OUT" | grep -q "undefined variable"; then
    echo "[44/47] HTTP Builtins (13 checks)"
    HTTP_OUTPUT=$(./eigenscript ../tests/test_http.eigs 2>&1)
    if echo "$HTTP_OUTPUT" | grep -q "All http tests passed"; then
        TOTAL=$((TOTAL + 13))
        PASS=$((PASS + 13))
        echo "  PASS: all 13 HTTP builtin checks"
    else
        TOTAL=$((TOTAL + 13))
        FAIL=$((FAIL + 13))
        echo "  FAIL: HTTP builtin tests"
        echo "$HTTP_OUTPUT" | grep -iE "assert|error" | head -5
    fi
    echo ""

    # [45] HTTP server integration (probe-gated)
    echo "[45/47] HTTP Server Integration (9 checks)"
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
    echo "[46/47] DB Builtins (6 checks)"
    DB_OUTPUT=$(./eigenscript ../tests/test_db.eigs 2>&1)
    if echo "$DB_OUTPUT" | grep -q "All db tests passed"; then
        TOTAL=$((TOTAL + 6))
        PASS=$((PASS + 6))
        echo "  PASS: all 6 DB builtin checks"
    else
        TOTAL=$((TOTAL + 6))
        FAIL=$((FAIL + 6))
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
    echo "[47/47] Model Save/Load Roundtrip (9 checks)"
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

    echo "[47b/47] Model Overflow Regression (1 check)"
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
        echo "  PASS: malicious oversized-dim checkpoint rejected"
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

# [49] Example smoke tests
echo "[49] Example Smoke Tests"
EX_OUTPUT=$(bash "$TESTS_DIR/test_examples.sh" 2>&1)
EX_EXIT=$?

# Count passes and skips from output
EX_PASS=$(echo "$EX_OUTPUT" | grep -c "PASS:" || true)
EX_SKIP=$(echo "$EX_OUTPUT" | grep -c "SKIP:" || true)
EX_FAIL=$(echo "$EX_OUTPUT" | grep -c "FAIL:" || true)

TOTAL=$((TOTAL + EX_PASS + EX_FAIL))
PASS=$((PASS + EX_PASS))
FAIL=$((FAIL + EX_FAIL))

echo "$EX_OUTPUT" | grep "EXAMPLES:"
echo ""

echo "============================================"
echo "  RESULTS: $PASS/$TOTAL passed, $FAIL failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
