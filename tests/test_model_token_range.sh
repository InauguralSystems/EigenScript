#!/bin/bash
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="${EIGS_BIN:-$TESTS_DIR/../src/eigenscript}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs_token_range.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

"$EIGS" "$TESTS_DIR/gen_tiny_model.eigs" > "$WORK/model.json" || exit 1
cat > "$WORK/check.eigs" <<EIGS
eigen_model_load of "$WORK/model.json"
define rejects(label, thunk) as:
    try:
        thunk of null
        assert of [false, f"{label} accepted bad token"]
    catch e:
        assert of [e.kind == "index_range", f"{label} raises index_range"]
        print of f"PASS {label}"
define bad_generate(_) as:
    return eigen_generate of [[0, 8], 0, 1]
define bad_eval_prompt(_) as:
    return eigen_eval_loss of [[-1], 0]
define bad_eval_target(_) as:
    return eigen_eval_loss of [[0], 8]
define bad_train_input(_) as:
    return native_train_step_builtin of [[0, 8], [1], 0.01]
define bad_train_output(_) as:
    return native_train_step_builtin of [[0], [1, -1], 0.01]
rejects of ["eigen_generate", bad_generate]
rejects of ["eigen_eval_loss prompt", bad_eval_prompt]
rejects of ["eigen_eval_loss target", bad_eval_target]
rejects of ["native_train_step input", bad_train_input]
rejects of ["native_train_step output", bad_train_output]
print of "MODEL TOKEN RANGE ALL PASS"
EIGS

for tier in interp default osr; do
    case "$tier" in
        interp) EIGS_JIT_OFF=1 "$EIGS" "$WORK/check.eigs" > "$WORK/$tier.out" 2> "$WORK/$tier.err" ;;
        default) "$EIGS" "$WORK/check.eigs" > "$WORK/$tier.out" 2> "$WORK/$tier.err" ;;
        osr) EIGS_JIT_OSR_THRESHOLD=1 "$EIGS" "$WORK/check.eigs" > "$WORK/$tier.out" 2> "$WORK/$tier.err" ;;
    esac
    rc=$?
    if [ "$rc" -ne 0 ] || ! grep -q '^MODEL TOKEN RANGE ALL PASS$' "$WORK/$tier.out" || grep -q '^FAIL ' "$WORK/$tier.out"; then
        echo "FAIL model token range ($tier, rc=$rc)"
        cat "$WORK/$tier.out" "$WORK/$tier.err"
        exit 1
    fi
    echo "  PASS: model token range ($tier)"
done

# A caught, model-dependent refusal is itself a typed tape outcome. It must
# replay without consulting the model and must not consume the following
# successful generation record (or the random record after that).
cat > "$WORK/replay.eigs" <<EIGS
eigen_model_load of "$WORK/model.json"
try:
    eigen_generate of [[8], 0, 1]
    assert of [false, "invalid generation unexpectedly succeeded"]
catch e:
    assert of [e.kind == "index_range", "record/replay refusal kind"]
    print of "caught index_range"
print of (eigen_generate of [[0], 0, 1])
print of (random_int of [0, 1000])
print of "MODEL TOKEN REPLAY ALL PASS"
EIGS
EIGS_JIT_OFF=1 EIGS_TRACE="$WORK/replay.tape" "$EIGS" "$WORK/replay.eigs" \
    > "$WORK/record.out" 2> "$WORK/record.err"
record_rc=$?
EIGS_JIT_OFF=1 EIGS_REPLAY="$WORK/replay.tape" EIGS_REPLAY_STRICT=1 \
    "$EIGS" "$WORK/replay.eigs" > "$WORK/replay-same.out" 2> "$WORK/replay-same.err"
same_rc=$?
mv "$WORK/model.json" "$WORK/model.missing"
EIGS_JIT_OFF=1 EIGS_REPLAY="$WORK/replay.tape" EIGS_REPLAY_STRICT=1 \
    "$EIGS" "$WORK/replay.eigs" > "$WORK/replay-missing.out" 2> "$WORK/replay-missing.err"
missing_rc=$?
sed -n '/^caught index_range$/,$p' "$WORK/record.out" > "$WORK/record.calls"
sed -n '/^caught index_range$/,$p' "$WORK/replay-same.out" > "$WORK/replay-same.calls"
sed -n '/^caught index_range$/,$p' "$WORK/replay-missing.out" > "$WORK/replay-missing.calls"
if [ "$record_rc" -ne 0 ] || [ "$same_rc" -ne 0 ] || [ "$missing_rc" -ne 0 ] || \
   ! cmp -s "$WORK/record.calls" "$WORK/replay-same.calls" || \
   ! cmp -s "$WORK/record.calls" "$WORK/replay-missing.calls" || \
   ! grep -q '^MODEL TOKEN REPLAY ALL PASS$' "$WORK/replay-missing.out"; then
    echo "FAIL model token strict replay (record=$record_rc same=$same_rc missing=$missing_rc)"
    diff -u "$WORK/record.calls" "$WORK/replay-same.calls" || true
    diff -u "$WORK/record.calls" "$WORK/replay-missing.calls" || true
    cat "$WORK/record.err" "$WORK/replay-same.err" "$WORK/replay-missing.err"
    exit 1
fi
echo "  PASS: model token refusal preserves strict replay tape (same and missing model)"
echo "MODEL TOKEN RANGE: 4 passed, 0 failed"
