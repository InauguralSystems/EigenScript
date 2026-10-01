#!/bin/bash
# Model inference must reject prompts beyond max_seq_len (#1405).

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$TESTS_DIR/../src/eigenscript"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

MODEL=/tmp/eigs_context_window_model.json
HARNESS=/tmp/eigs_context_window_harness.eigs
cleanup() { rm -f "$MODEL" "$HARNESS" /tmp/eigs_context_window_*.log /tmp/eigs_context_window.tape; }
trap cleanup EXIT

if ! "$EIGS" "$TESTS_DIR/gen_tiny_model.eigs" > "$MODEL" 2>/tmp/eigs_context_window_gen.log; then
    fail "CW00 generate tiny model" "see /tmp/eigs_context_window_gen.log"
    echo "MODEL CONTEXT WINDOW: 0 passed, 1 failed"
    exit 1
fi

cat > "$HARNESS" <<EIGS
eigen_model_load of "$MODEL"
long is range of 20
try:
    eigen_generate of [long, 0, 4]
    print of "generation accepted"
catch e:
    print of e.message
try:
    eigen_eval_loss of [long, 3]
    print of "eval accepted"
catch e:
    print of e.message
EIGS

OUT_FILE=/tmp/eigs_context_window_stdout.log
ERR_FILE=/tmp/eigs_context_window_stderr.log
"$EIGS" "$HARNESS" >"$OUT_FILE" 2>"$ERR_FILE"
RC=$?
OUT=$(cat "$OUT_FILE")
ERR=$(cat "$ERR_FILE")

if [ "$RC" -eq 0 ]; then
    ok "CW01 inference overflow harness exits cleanly"
else
    fail "CW01 inference overflow harness exits cleanly" "rc=$RC, stderr='$ERR'"
fi

EXPECTED_ERR="[model-load] No live weights, using locked baseline: $MODEL"
if [ "$ERR" = "$EXPECTED_ERR" ]; then
    ok "CW02 inference overflow harness has only the expected model-load diagnostic"
else
    fail "CW02 inference overflow harness has only the expected model-load diagnostic" "stderr='$ERR'"
fi

CHECK=3
for expected in \
    "eigen_generate: prompt length 20 exceeds model max_seq_len 16" \
    "eigen_eval_loss: prompt length 20 exceeds model max_seq_len 16"
do
    if [ "$(printf '%s\n' "$OUT" | grep -Fxc "$expected" || true)" -eq 1 ]; then
        ok "CW0$CHECK $expected"
    else
        fail "CW0$CHECK overlong inference prompt is rejected" "expected '$expected'; stdout='$OUT'; stderr='$ERR'"
    fi
    CHECK=$((CHECK+1))
done

# A raising nondeterministic call has no N record. Replay must validate it
# before taking the next record, or it will consume the valid call's tokens and
# silently bypass the exception.
cat > "$HARNESS" <<EIGS
eigen_model_load of "$MODEL"
long is range of 20
try:
    eigen_generate of [long, 0, 4]
    print of "generation accepted"
catch e:
    print of e.message
print of (eigen_generate of [[1, 2, 3], 0, 4])
EIGS

TAPE=/tmp/eigs_context_window.tape
TRACE_OUT=$(EIGS_TRACE="$TAPE" "$EIGS" "$HARNESS" 2>/dev/null)
REPLAY_OUT=$(EIGS_REPLAY="$TAPE" "$EIGS" "$HARNESS" 2>/dev/null)
NREC=$(grep -c '^N eigen_generate=' "$TAPE" 2>/dev/null || true)
REPLAY_ERRORS=$(printf '%s\n' "$REPLAY_OUT" |
    grep -Fxc 'eigen_generate: prompt length 20 exceeds model max_seq_len 16' || true)
if [ "$NREC" -eq 1 ] && [ "$REPLAY_OUT" = "$TRACE_OUT" ] && [ "$REPLAY_ERRORS" -eq 1 ]; then
    ok "CW05 rejected generation preserves replay tape alignment"
else
    fail "CW05 rejected generation preserves replay tape alignment" \
        "records=$NREC; trace='$TRACE_OUT'; replay='$REPLAY_OUT'"
fi

echo "MODEL CONTEXT WINDOW: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
