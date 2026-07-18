#!/bin/bash
# native_train_step gradient-check: the batched causal-mask path must produce
# the SAME training as the per-position oracle. A causal transformer trained
# per-position (one forward+backward per target) is mathematically identical to
# one causal-masked pass with a loss at every position — the batched path is
# ~10x faster and must not change the gradients. Any drift would diverge the
# two loss sequences within a few steps (gradient errors compound), so matching
# loss sequences from a common start prove equivalence.
#
# Runs only when the binary is built with EIGENSCRIPT_EXT_MODEL=1 (gated by the
# caller). EIGS_TRAIN_PERPOS=1 selects the oracle; default selects batched.

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$TESTS_DIR/../src/eigenscript"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

MODEL=/tmp/eigs_gc_tiny.json
HARNESS=/tmp/eigs_gc_harness.eigs
cleanup() { rm -f "$MODEL" "$HARNESS" /tmp/eigs_gc_*.log; }
trap cleanup EXIT

if ! "$EIGS" "$TESTS_DIR/gen_tiny_model.eigs" > "$MODEL" 2>/tmp/eigs_gc_gen.log; then
    fail "GC00 generate tiny model" "see /tmp/eigs_gc_gen.log"
    echo "GRADCHECK: 0 passed, 1 failed"
    exit 1
fi

# Fixed deterministic window (all token ids < vocab=8). Six steps is enough:
# a gradient bug diverges exponentially, so it would show by step 2-3.
cat > "$HARNESS" <<EIGS
r is eigen_model_load of "$MODEL"
inp is [1, 2, 3, 4, 5, 6, 7]
outp is [1]
lr is 0.05
for i in range of 6:
    res is native_train_step_builtin of [inp, outp, lr]
    lv is json_path of [res, "loss"]
    print of ("L " + lv)
EIGS

# Extract the loss sequence from each path.
perpos=$(EIGS_TRAIN_PERPOS=1 "$EIGS" "$HARNESS" 2>/dev/null | sed -n 's/^L //p')
batched=$("$EIGS" "$HARNESS" 2>/dev/null | sed -n 's/^L //p')

if [ -z "$perpos" ] || [ -z "$batched" ]; then
    fail "GC01 both paths produced a loss sequence" "perpos='$perpos' batched='$batched'"
    echo "GRADCHECK: $PASS passed, $((FAIL)) failed"
    exit 1
fi
ok "GC01 both paths produced a loss sequence"

# Compare element-wise. A real gradient difference compounds well past 1e-3
# within six steps; float32 accumulation-order noise stays under ~1e-4.
n_perpos=$(printf '%s\n' "$perpos" | wc -l)
n_batched=$(printf '%s\n' "$batched" | wc -l)
if [ "$n_perpos" != "$n_batched" ] || [ "$n_perpos" -lt 6 ]; then
    fail "GC02 equal-length 6-step sequences" "perpos=$n_perpos batched=$n_batched"
else
    ok "GC02 both paths ran 6 steps"
fi

maxdiff=$(paste <(printf '%s\n' "$perpos") <(printf '%s\n' "$batched") | awk '
    { d = $1 - $2; if (d < 0) d = -d; if (d > m) m = d }
    END { printf "%.8f", m }')
worse=$(awk -v m="$maxdiff" 'BEGIN { print (m > 0.001) ? 1 : 0 }')
if [ "$worse" = "0" ]; then
    ok "GC03 batched loss sequence matches per-position oracle (max diff $maxdiff < 1e-3)"
else
    fail "GC03 batched vs per-position gradient divergence" "max loss diff = $maxdiff"
    echo "  perpos : $(printf '%s ' $perpos)"
    echo "  batched: $(printf '%s ' $batched)"
fi

echo "GRADCHECK: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
