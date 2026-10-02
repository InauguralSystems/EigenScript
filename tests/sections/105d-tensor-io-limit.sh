# Tensor-file cap contract (#1393); sourced by the suite fragment seam.
echo "[105d] Tensor file limit and writer/reader symmetry (#1393)"
TIL_OUTPUT=$(EIGENSCRIPT=./eigenscript bash "$TESTS_DIR/test_tensor_io_limit.sh" 2>&1); TIL_RC=$?
TOTAL=$((TOTAL + 1))
if rc_ok "$TIL_RC" "$TIL_OUTPUT" && echo "$TIL_OUTPUT" | grep -q "All tests passed"; then
    PASS=$((PASS + 1))
    echo "  PASS: tensor file limit program completed all checks"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: tensor file limit checks (rc=$TIL_RC)"
    echo "$TIL_OUTPUT" | tail -20
fi
echo ""
