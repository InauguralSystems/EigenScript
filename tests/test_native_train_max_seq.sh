#!/bin/bash
# native_train_step must refuse windows larger than the model's configured
# context before allocating or writing its TrainingCache (#1401).

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$TESTS_DIR/../src/eigenscript"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

MODEL=/tmp/eigs_train_max_seq_model.json
HARNESS=/tmp/eigs_train_max_seq_harness.eigs
cleanup() { rm -f "$MODEL" "$HARNESS" /tmp/eigs_train_max_seq_*.log; }
trap cleanup EXIT

if ! "$EIGS" "$TESTS_DIR/gen_tiny_model.eigs" > "$MODEL" 2>/tmp/eigs_train_max_seq_gen.log; then
    fail "MS00 generate tiny model" "see /tmp/eigs_train_max_seq_gen.log"
    echo "TRAIN MAX SEQ: 0 passed, 1 failed"
    exit 1
fi

cat > "$HARNESS" <<EIGS
eigen_model_load of "$MODEL"
for n in [17, 64]:
    try:
        native_train_step_builtin of [range of (n - 1), [1], 0.01]
        print of ("accepted " + n)
    catch e:
        print of e.message
EIGS

OUTPUT=$("$EIGS" "$HARNESS" 2>&1)
RC=$?
if [ "$RC" -eq 0 ]; then
    ok "MS01 over-long windows exit cleanly"
else
    fail "MS01 over-long windows exit cleanly" "rc=$RC"
fi

for n in 17 64; do
    expected="native_train_step: sequence length $n exceeds model max_seq_len 16"
    count=$(printf '%s\n' "$OUTPUT" | grep -Fxc "$expected" || true)
    if [ "$count" -eq 1 ]; then
        ok "MS$n full_len=$n is refused before training"
    else
        fail "MS$n full_len=$n is refused before training" "expected '$expected'; output='$OUTPUT'"
    fi
done

echo "TRAIN MAX SEQ: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
