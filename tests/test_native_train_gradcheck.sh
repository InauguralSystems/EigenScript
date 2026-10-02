#!/bin/bash
# Independent finite-difference check for native_train_step's shared backward.
# Runs only when EIGENSCRIPT_EXT_MODEL=1 (the suite capability-gates it).

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$TESTS_DIR/../src/eigenscript"
WORK="${TMPDIR:-/tmp}/eigs_native_gradcheck_$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
if ! source "$TESTS_DIR/lsan_classify.sh"; then
    echo "  FAIL: NG00 load canonical sanitizer classifier"
    echo "NATIVE_GRADCHECK: 0 passed, 1 failed"
    exit 1
fi

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
lsan_classify "$(cat "$BASE" "$WORK/gen.log")"
GEN_CLASS=$?
if [ "$GEN_CLASS" -ne 2 ]; then
    echo "  FAIL: NG00 generator sanitizer diagnostic (classifier=$GEN_CLASS)"
    cat "$WORK/gen.log"
    echo "NATIVE_GRADCHECK: 0 passed, 1 failed"
    exit 1
fi

if ! python3 "$TESTS_DIR/native_train_gradcheck.py" "$EIGS" "$BASE" "$WORK"; then
    exit 1
fi

# Fault-sensitivity plant: a systematic 2% error is outside the declared 1%
# contract and must be rejected.  Silence the expected-red child's details so
# the parent suite counts only this plant's verdict.
if EIGS_GRADCHECK_FAULT_SCALE=1.02 \
        python3 "$TESTS_DIR/native_train_gradcheck.py" "$EIGS" "$BASE" "$WORK" \
        >"$WORK/fault.log" 2>&1; then
    echo "  FAIL: NG03 a deliberately 2%-wrong backward derivative passed"
    echo "NATIVE_GRADCHECK: 0 passed, 1 failed"
    exit 1
fi
if ! grep -q "FAIL: NG01" "$WORK/fault.log"; then
    echo "  FAIL: NG03 fault child failed without rejecting a derivative"
    echo "NATIVE_GRADCHECK: 0 passed, 1 failed"
    exit 1
fi
echo "  PASS: NG03 deliberately 2%-wrong derivatives are rejected"
