#!/bin/bash
# Example smoke test harness.
# Runs every .eigs example, checks exit code and key output markers.
# Slow examples (>2s) are opt-in via EIGEN_TEST_SLOW=1.

cd "$(dirname "$0")/.."

EIGENSCRIPT="./src/eigenscript"
if [ ! -x "$EIGENSCRIPT" ]; then
    EIGENSCRIPT=$(which eigenscript 2>/dev/null)
fi

PASS=0
FAIL=0
SKIP=0
TOTAL=0

# Slow examples: require EIGEN_TEST_SLOW=1
SLOW_EXAMPLES="sdf conway"

run_example() {
    local name="$1"
    local file="examples/${name}.eigs"
    local timeout_sec="${2:-10}"
    local expect_output="$3"  # optional substring to check in output

    TOTAL=$((TOTAL + 1))

    # Check if slow and not opted in
    for slow in $SLOW_EXAMPLES; do
        if [ "$name" = "$slow" ] && [ "${EIGEN_TEST_SLOW:-0}" != "1" ]; then
            echo "  SKIP: $name (slow, set EIGEN_TEST_SLOW=1)"
            SKIP=$((SKIP + 1))
            return
        fi
    done

    local output
    output=$(timeout "$timeout_sec" $EIGENSCRIPT "$file" 2>/dev/null)
    local rc=$?

    if [ $rc -ne 0 ]; then
        echo "  FAIL: $name (exit code $rc)"
        FAIL=$((FAIL + 1))
        return
    fi

    # Check for runtime errors (stderr lines that indicate real problems)
    # Exclude the idioms example which intentionally demonstrates errors
    if [ "$name" != "idioms" ]; then
        if echo "$output" | grep -q "ASSERT FAIL"; then
            echo "  FAIL: $name (assert failure)"
            FAIL=$((FAIL + 1))
            return
        fi
    fi

    # Check expected output substring if provided
    if [ -n "$expect_output" ]; then
        if ! echo "$output" | grep -q "$expect_output"; then
            echo "  FAIL: $name (expected '$expect_output' in output)"
            FAIL=$((FAIL + 1))
            return
        fi
    fi

    echo "  PASS: $name"
    PASS=$((PASS + 1))
}

echo "Example smoke tests"
echo ""

# ---- Core EigenScript examples (heavily weighted in corpus) ----
echo "Core idiom examples:"
run_example "observer_predicates" 30 "converged as termination"
run_example "self_referential" 10 "All string_math\|token_name\|VALID"
run_example "idioms" 30 "expected 210"
run_example "numerical" 30 "Newton"
run_example "observer" 10 "Observer state"
echo ""

# ---- General examples ----
echo "General examples:"
run_example "hello" 5 "Hello"
run_example "basics" 10 "5!"
run_example "fizzbuzz" 5 "FizzBuzz"
run_example "fibonacci" 10 "First 15"
run_example "sort" 10 "After"
run_example "calculator" 10 "Calculator"
run_example "state_machine" 10 "Tokenizer"
run_example "text_processor" 10 "Palindrome"
run_example "data_structures" 10 "Linked List"
run_example "game_logic" 10 "wins"
run_example "functional" 10 "Composition"
run_example "registry" 10 "Key-Value"
run_example "data_pipeline" 10 "Report Card"
run_example "json_config" 10 "Config JSON"
run_example "stdlib_demo" 10 "map double"
run_example "tensors" 10 "Softmax"
echo ""

# ---- Simulation examples ----
echo "Simulation examples:"
run_example "physics" 10 "Rigid Body"
run_example "rope" 10 "Rope Simulation"
run_example "orbital" 10 "Orbital Mechanics"
run_example "pid" 15 "PID"
run_example "ik" 10 "Inverse Kinematics"
run_example "sokoban" 10 "Sokoban"
run_example "conway" 30 "Glider"
run_example "sdf" 30 "SDF Ray"
echo ""

echo "============================================"
echo "  EXAMPLES: $PASS passed, $FAIL failed, $SKIP skipped ($TOTAL total)"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
