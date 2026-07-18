#!/bin/bash
# eigen_eval_loss: forward-only held-out cross-entropy.
#
# The property that pins this down without needing a trained model: an
# UNTRAINED model's output distribution is near-uniform over the vocabulary,
# so its cross-entropy must sit at ln(vocab_size) whatever the target is. The
# tiny fixture has vocab=8, so every loss must land near ln(8) = 2.0794.
#
# That single anchor catches the realistic failure modes at once -- a missing
# max-subtraction (overflow -> inf), summing the softmax over the wrong axis,
# indexing the wrong target, or returning logits instead of a loss would all
# miss ln(8). It also catches sign errors, since a cross-entropy is never
# negative.
#
# Runs only when the binary is built with EIGENSCRIPT_EXT_MODEL=1.

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$TESTS_DIR/../src/eigenscript"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

MODEL=/tmp/eigs_el_tiny.json
HARNESS=/tmp/eigs_el_harness.eigs
cleanup() { rm -f "$MODEL" "$HARNESS" /tmp/eigs_el_*.log; }
trap cleanup EXIT

if ! "$EIGS" "$TESTS_DIR/gen_tiny_model.eigs" > "$MODEL" 2>/tmp/eigs_el_gen.log; then
    fail "EL00 generate tiny model" "see /tmp/eigs_el_gen.log"
    echo "EVALLOSS: 0 passed, 1 failed"
    exit 1
fi

cat > "$HARNESS" <<EIGS
r is eigen_model_load of "$MODEL"
prompt is [1, 2, 3, 4]
# Every vocab target on an untrained model: all must be near ln(8).
for t in range of 8:
    l is eigen_eval_loss of [prompt, t]
    print of ("L " + (str of l))
# Out-of-range target must be rejected with the -1 sentinel, not a garbage
# read past the logits array.
print of ("OOR " + (str of (eigen_eval_loss of [prompt, 999])))
print of ("NEG " + (str of (eigen_eval_loss of [prompt, 0 - 1])))
EIGS

OUT=$("$EIGS" "$HARNESS" 2>/dev/null)
LOSSES=$(printf '%s\n' "$OUT" | sed -n 's/^L //p')

if [ -z "$LOSSES" ]; then
    fail "EL01 eigen_eval_loss returned values" "no output"
    echo "EVALLOSS: $PASS passed, $((FAIL+1)) failed"
    exit 1
fi
ok "EL01 eigen_eval_loss returned a loss for every target"

# All 8 losses within 0.35 nats of ln(8). The band is wide enough for the
# fixture's small random weights to tilt the distribution, tight enough that
# any structural error lands far outside it.
BAD=$(printf '%s\n' "$LOSSES" | awk '
    BEGIN { ln8 = 2.0794415; bad = 0 }
    { d = $1 - ln8; if (d < 0) d = -d; if (d > 0.35) bad++ }
    END { print bad }')
if [ "$BAD" = "0" ]; then
    ok "EL02 untrained losses sit at ln(vocab) (all 8 within 0.35 of 2.0794)"
else
    fail "EL02 untrained losses deviate from ln(vocab)" "$BAD of 8 outside band"
    echo "  losses: $(printf '%s ' $LOSSES)"
fi

NONNEG=$(printf '%s\n' "$LOSSES" | awk '{ if ($1 < 0) n++ } END { print n+0 }')
if [ "$NONNEG" = "0" ]; then
    ok "EL03 no negative cross-entropy"
else
    fail "EL03 negative cross-entropy returned" "$NONNEG value(s) < 0"
fi

OOR=$(printf '%s\n' "$OUT" | sed -n 's/^OOR //p')
NEG=$(printf '%s\n' "$OUT" | sed -n 's/^NEG //p')
if [ "${OOR%%.*}" = "-1" ] && [ "${NEG%%.*}" = "-1" ]; then
    ok "EL04 out-of-range targets rejected with the -1 sentinel"
else
    fail "EL04 out-of-range target not rejected" "target=999 -> '$OOR', target=-1 -> '$NEG'"
fi

echo "EVALLOSS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
