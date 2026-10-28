# [99aaf] Child-owned check-plan calibration (#2051).
echo "[99aaf] child-owned check plan calibration (#2051)"
CP_OUT=$(bash "$TESTS_DIR/test_child_plan_calibration.sh" 2>&1); CP_RC=$?
TOTAL=$((TOTAL + 1))
if child_plan_ok "$CP_OUT" "$CP_RC" "^  PASS:" "^  FAIL:"; then
    PASS=$((PASS + 1)); echo "  PASS: child completed its declared plan"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: child plan contract: $CHILD_PLAN_ERROR"
fi
printf '%s\n' "$CP_OUT"
echo ""
