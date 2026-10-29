echo "[2162] Null slice diagnostic (#2162)"
SLICE_NULL_OUTPUT=$(bash "$TESTS_DIR/test_slice_null_diagnostic_2162.sh" 2>&1); SLICE_NULL_RC=$?
TOTAL=$((TOTAL + 1))
if child_plan_ok "$SLICE_NULL_OUTPUT" "$SLICE_NULL_RC" "^PASS:" "^FAIL:"; then
    PASS=$((PASS + 1))
    printf '%s\n' "$SLICE_NULL_OUTPUT"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: null slice diagnostic child contract: $CHILD_PLAN_ERROR"
    printf '%s\n' "$SLICE_NULL_OUTPUT" | sed 's/^/    /'
fi
