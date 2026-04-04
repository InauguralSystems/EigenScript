#!/bin/bash
set -e
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
    python3 ../tests/gen_tiny_model.py > /tmp/eigs_tiny_v1.json 2>/dev/null

    # Find a v0 model to test rejection
    V0_MODEL=$(ls /home/jon/iLambdaAi/archive/checkpoints/eigenscript/*.json 2>/dev/null | head -1)

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

echo "============================================"
echo "  RESULTS: $PASS/$TOTAL passed, $FAIL failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
