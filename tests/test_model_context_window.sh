#!/bin/bash
# Model inference must retain the newest max_seq_len prompt tokens (#1405).

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$TESTS_DIR/../src/eigenscript"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

MODEL=/tmp/eigs_context_window_model.json
HARNESS=/tmp/eigs_context_window_harness.eigs
cleanup() { rm -f "$MODEL" "$HARNESS" /tmp/eigs_context_window_*.log; }
trap cleanup EXIT

if ! "$EIGS" "$TESTS_DIR/gen_tiny_model.eigs" > "$MODEL" 2>/tmp/eigs_context_window_gen.log; then
    fail "CW00 generate tiny model" "see /tmp/eigs_context_window_gen.log"
    echo "MODEL CONTEXT WINDOW: 0 passed, 1 failed"
    exit 1
fi

cat > "$HARNESS" <<EIGS
eigen_model_load of "$MODEL"
long is range of 20
tail is range of [4, 20]
print of ("GL " + (str of (eigen_generate of [long, 0, 4])))
print of ("GT " + (str of (eigen_generate of [tail, 0, 4])))
print of ("EL " + (str of (eigen_eval_loss of [long, 3])))
print of ("ET " + (str of (eigen_eval_loss of [tail, 3])))
EIGS

OUT=$("$EIGS" "$HARNESS" 2>/dev/null)
GL=$(printf '%s\n' "$OUT" | sed -n 's/^GL //p')
GT=$(printf '%s\n' "$OUT" | sed -n 's/^GT //p')
EL=$(printf '%s\n' "$OUT" | sed -n 's/^EL //p')
ET=$(printf '%s\n' "$OUT" | sed -n 's/^ET //p')

if [ -n "$GL" ] && [ "$GL" = "$GT" ]; then
    ok "CW01 greedy generation uses the last max_seq_len prompt tokens"
else
    fail "CW01 greedy generation uses the last max_seq_len prompt tokens" "long='$GL', tail='$GT'"
fi

if [ -n "$EL" ] && [ "$EL" = "$ET" ]; then
    ok "CW02 eval loss uses the last max_seq_len prompt tokens"
else
    fail "CW02 eval loss uses the last max_seq_len prompt tokens" "long='$EL', tail='$ET'"
fi

echo "MODEL CONTEXT WINDOW: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
