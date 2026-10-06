#!/bin/bash
# Ordinary tiny-model context boundaries and replay alignment (#1405).
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="${EIGS_BIN:-$TESTS_DIR/../src/eigenscript}"
. "$TESTS_DIR/lsan_classify.sh"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }
summary() { echo "MODEL CONTEXT WINDOW: $PASS passed, $FAIL failed"; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs_context_window.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT

# Every runtime invocation uses this path, including fixture generation and
# replay. Sanitizer diagnostics are failures even when the process exits zero.
run_clean() {
    local name="$1" expected_err="$2" rc out err classification
    shift 2
    "$@" >"$WORK/$name.out" 2>"$WORK/$name.err"; rc=$?
    out=$(cat "$WORK/$name.out")
    err=$(cat "$WORK/$name.err")
    classification=$(lsan_classify_name "$out
$err")
    if [ "$rc" -ne 0 ] || [ "$classification" != none ] || [ "$err" != "$expected_err" ]; then
        fail "$name clean runtime exit" "rc=$rc; sanitizer=$classification; stdout='$out'; stderr='$err'"
        return 1
    fi
    ok "$name clean runtime exit"
}

if ! run_clean CW00 '' "$EIGS" "$TESTS_DIR/gen_tiny_model.eigs"; then
    summary
    exit 1
fi
MODEL="$WORK/model.json"
mv "$WORK/CW00.out" "$MODEL"
HARNESS="$WORK/context.eigs"
EXPECTED_ERR="[model-load] No live weights, using locked baseline: $MODEL"

cat > "$HARNESS" <<EIGS
eigen_model_load of "$MODEL"
assert of [(eigen_model_loaded of null), "tiny model loaded"]
for n in [15, 16]:
    prompt is [i % 8 for i in range of n]
    generated is eigen_generate of [prompt, 0, 4]
    assert of [(len of generated) > 0 and (len of generated) <= 4, "generation at boundary"]
    assert of [(eigen_eval_loss of [prompt, 3]) >= 0, "eval at boundary"]
    print of f"accepted {n}"
long is [i % 8 for i in range of 17]
try:
    eigen_generate of [long, 0, 4]
    print of "generation accepted"
catch e:
    print of f"{e.kind}: {e.message}"
try:
    eigen_eval_loss of [long, 3]
    print of "eval accepted"
catch e:
    print of f"{e.kind}: {e.message}"
try:
    native_train_step_builtin of [range of 16, [1], 0.01]
    print of "training accepted"
catch e:
    print of f"{e.kind}: {e.message}"
EIGS
MODEL_BYTES=$(wc -c < "$MODEL" | tr -d ' ')
cat > "$WORK/expected.out" <<EXPECTED
Loading model from: $MODEL
Model file loaded: $MODEL_BYTES bytes
Config: vocab=8 d_model=4 n_layers=1 d_ff=8
Model loaded successfully: v2 (ternary-weight-only), 1 layers, d_model=4
accepted 15
accepted 16
value: eigen_generate: prompt length 17 exceeds model max_seq_len 16
value: eigen_eval_loss: prompt length 17 exceeds model max_seq_len 16
value: native_train_step: sequence length 17 exceeds model max_seq_len 16
EXPECTED

for strict in 0 1; do
    run_clean "CW-strict-$strict" "$EXPECTED_ERR" env EIGS_STRICT="$strict" "$EIGS" "$HARNESS"
    if cmp -s "$WORK/expected.out" "$WORK/CW-strict-$strict.out"; then
        ok "CW-strict-$strict inference boundaries and training refusal agree"
    else
        fail "CW-strict-$strict context contract"
        diff -u "$WORK/expected.out" "$WORK/CW-strict-$strict.out"
    fi
done

# Generation outcomes must survive changes to the external model. Compare
# the raw generation transcript after the loader's informational banner.
cp "$MODEL" "$WORK/original.json"
sed 's/"max_seq_len":16/"max_seq_len":24/' "$MODEL" > "$WORK/larger.json"
sed 's/"max_seq_len":16/"max_seq_len":8/' "$MODEL" > "$WORK/smaller.json"
cat > "$WORK/generation.eigs" <<'EIGS'
print of "CW transcript"
long is [i % 8 for i in range of 17]
try:
    eigen_generate of [long, 0, 4]
    print of "generation accepted"
catch e:
    print of f"{e.kind}: {e.message}"
for prompt in [[i % 8 for i in range of 16], [1, 2, 3]]:
    generated is eigen_generate of [prompt, 0, 4]
    assert of [(len of generated) == 4, "valid generation follows refusal"]
    print of generated
print of (random_int of [11, 19])
EIGS
printf 'eigen_model_load of "%s"\n' "$MODEL" > "$HARNESS"
cat "$WORK/generation.eigs" >> "$HARNESS"
for jit_off in 0 1; do
    cp "$WORK/original.json" "$MODEL"
    tape="$WORK/replay-$jit_off.tape"
    trace_name="CW-trace-$jit_off"
    run_clean "$trace_name" "$EXPECTED_ERR" env EIGS_JIT_OFF="$jit_off" EIGS_TRACE="$tape" "$EIGS" "$HARNESS"
    sed -n '/^CW transcript$/,$p' "$WORK/$trace_name.out" > "$WORK/recorded.out"
    nrec=$(grep -c '^N [0-9][0-9]* eigen_generate=' "$tape")
    nlists=$(grep -c '^N [0-9][0-9]* eigen_generate=\[' "$tape")
    nrefusals=$(grep -c '^N [0-9][0-9]* eigen_generate="eigen_generate: prompt length 17 exceeds model max_seq_len 16"$' "$tape")
    nrandom=$(grep -c '^N [0-9][0-9]* random_int=' "$tape")
    if [ "$nrec" = 3 ] && [ "$nlists" = 2 ] && [ "$nrefusals" = 1 ] && [ "$nrandom" = 1 ]; then
        ok "CW-trace-$jit_off one outcome per call, successful lists unchanged"
    else
        fail "CW-trace-$jit_off outcome records" "generation=$nrec; lists=$nlists; refusals=$nrefusals; random=$nrandom"
    fi
    for model_state in unchanged missing larger smaller; do
        replay_name="CW-replay-$jit_off-$model_state"
        replay_script="$HARNESS"
        replay_err="$EXPECTED_ERR"
        if [ "$model_state" = missing ]; then
            rm "$MODEL"
            replay_script="$WORK/generation.eigs"
            replay_err=''
        elif [ "$model_state" = unchanged ]; then
            cp "$WORK/original.json" "$MODEL"
        else
            cp "$WORK/$model_state.json" "$MODEL"
        fi
        run_clean "$replay_name" "$replay_err" env EIGS_JIT_OFF="$jit_off" EIGS_REPLAY="$tape" EIGS_REPLAY_STRICT=1 "$EIGS" "$replay_script"
        sed -n '/^CW transcript$/,$p' "$WORK/$replay_name.out" > "$WORK/replayed.out"
        refusals=$(grep -Fxc 'value: eigen_generate: prompt length 17 exceeds model max_seq_len 16' "$WORK/replayed.out")
        if [ "$refusals" = 1 ] && cmp -s "$WORK/recorded.out" "$WORK/replayed.out"; then
            ok "$replay_name preserves refusal, successes, and following random draw"
        else
            fail "$replay_name tape alignment" "refusals=$refusals"
            diff -u "$WORK/recorded.out" "$WORK/replayed.out"
        fi
    done
done

summary
[ "$FAIL" -eq 0 ]
