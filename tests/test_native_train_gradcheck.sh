#!/bin/bash
# Independent finite-difference check for native_train_step's shared backward.
# Runs only when EIGENSCRIPT_EXT_MODEL=1 (the suite capability-gates it).

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$TESTS_DIR/../src/eigenscript"
WORK="${TMPDIR:-/tmp}/eigs_native_gradcheck_$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

BASE="$WORK/base.json"
# Two layers exercise all 22 independently updated parameter groups.  FP32 is
# essential: ternary projection would make a small finite difference vanish.
sed -e 's/^n_layers is 1$/n_layers is 2/' \
    -e 's/^max_seq is 16$/max_seq is 32/' \
    -e 's/\\"ternary_weight_only\\"/\\"fp32_dense\\"/' \
    "$TESTS_DIR/gen_tiny_model.eigs" > "$WORK/gen.eigs"
if ! "$EIGS" "$WORK/gen.eigs" > "$BASE" 2>"$WORK/gen.log"; then
    echo "  FAIL: NG00 generate two-layer fp32 model (see $WORK/gen.log)"
    echo "NATIVE_GRADCHECK: 0 passed, 1 failed"
    exit 1
fi

python3 "$TESTS_DIR/native_train_gradcheck.py" "$EIGS" "$BASE" "$WORK"
