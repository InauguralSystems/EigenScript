echo "[0g0] Non-finite arguments to arithmetic builtins (#2444)"
NONFINITE_OUT=$(python3 "$TESTS_DIR/nonfinite_math.py" --binary "$EIGS" 2>&1)
NONFINITE_RC=$?
printf '%s\n' "$NONFINITE_OUT"
NONFINITE_PASS=$(grep -c '^PASS:' <<< "$NONFINITE_OUT")
NONFINITE_FAIL=$(grep -c '^FAIL:' <<< "$NONFINITE_OUT")
TOTAL=$((TOTAL + NONFINITE_PASS + NONFINITE_FAIL))
PASS=$((PASS + NONFINITE_PASS))
FAIL=$((FAIL + NONFINITE_FAIL))
if ! rc_ok "$NONFINITE_RC" "$NONFINITE_OUT" || [ "$NONFINITE_PASS" -eq 0 ]; then
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo "  FAIL: non-finite math child exit or empty population"
fi
echo ""
NONFINITE_TENSOR_OUT=$(python3 "$TESTS_DIR/nonfinite_tensor.py" --binary "$EIGS" 2>&1)
NONFINITE_TENSOR_RC=$?
printf '%s\n' "$NONFINITE_TENSOR_OUT"
NONFINITE_TENSOR_PASS=$(grep -c '^PASS:' <<< "$NONFINITE_TENSOR_OUT")
NONFINITE_TENSOR_FAIL=$(grep -c '^FAIL:' <<< "$NONFINITE_TENSOR_OUT")
TOTAL=$((TOTAL + NONFINITE_TENSOR_PASS + NONFINITE_TENSOR_FAIL))
PASS=$((PASS + NONFINITE_TENSOR_PASS))
FAIL=$((FAIL + NONFINITE_TENSOR_FAIL))
if ! rc_ok "$NONFINITE_TENSOR_RC" "$NONFINITE_TENSOR_OUT" || [ "$NONFINITE_TENSOR_PASS" -eq 0 ]; then
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo "  FAIL: non-finite tensor child exit or empty population"
fi
echo ""
