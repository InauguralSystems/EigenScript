#!/bin/bash
# Regression: a model checkpoint with out-of-range dims must be rejected
# at config-parse time, not allowed to overflow int*int in weight
# allocation and blow past the heap.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$TESTS_DIR/.." && pwd)/src"
BIN="$SRC_DIR/eigenscript"

PASS=0
FAIL=0

# Probe: model extension present? (Skip cleanly if built minimal.)
PROBE=$(mktemp /tmp/eigs_mo_XXXXXX.eigs)
cat > "$PROBE" <<'E'
r is eigen_model_load of "/nonexistent.json"
print of r
E
OUT=$("$BIN" "$PROBE" 2>&1)
rm -f "$PROBE"
if echo "$OUT" | grep -q "undefined variable"; then
    echo "SKIP: model extension not built (model_overflow)"
    exit 0
fi

# Build a malicious JSON: vocab_size=1000000000 (~1B) would overflow
# int*int when multiplied by d_model=1000000000, wrapping to a tiny
# allocation in the pre-fix code. With the fix, the config parser
# rejects anything above MODEL_MAX_DIM and returns a "status":"error".
MAL=$(mktemp /tmp/eigs_mal_XXXXXX.json)
cat > "$MAL" <<'E'
{
  "weight_format": "fp32_dense",
  "config": {
    "vocab_size": 1000000000,
    "d_model": 1000000000,
    "n_heads": 1,
    "n_layers": 1,
    "d_ff": 128,
    "max_seq_len": 128
  },
  "token_embeddings": [[0.0]]
}
E

SCRIPT=$(mktemp /tmp/eigs_mo_run_XXXXXX.eigs)
cat > "$SCRIPT" <<E
r is eigen_model_load of "$MAL"
if contains of [r, "error"]:
    print of "rejected"
else:
    print of "accepted"
E

# Run with 5s timeout — a successful exploit would either hang or SEGV.
OUT=$(timeout 5 "$BIN" "$SCRIPT" 2>&1)
RC=$?
rm -f "$MAL" "$SCRIPT"

if [ $RC -ne 0 ] && [ $RC -ne 1 ]; then
    echo "  FAIL: MO1 malicious checkpoint caused non-zero exit $RC (crash?)"
    FAIL=$((FAIL + 1))
elif echo "$OUT" | grep -q "rejected"; then
    echo "  PASS: MO1 malicious oversized-dim checkpoint rejected"
    PASS=$((PASS + 1))
else
    echo "  FAIL: MO1 malicious checkpoint unexpectedly accepted"
    echo "$OUT" | tail -5
    FAIL=$((FAIL + 1))
fi

echo ""
if [ $FAIL -gt 0 ]; then
    exit 1
fi
echo "All model-overflow tests passed"
exit 0
