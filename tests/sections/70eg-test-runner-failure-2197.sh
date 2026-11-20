echo "[70eg] Failed test-runner output remains clean (#2197)"
TR2197_OUT=$(EIGS="$EIGS" bash "$TESTS_DIR/test_test_runner_failure_2197.sh" 2>&1); TR2197_RC=$?
TOTAL=$((TOTAL + 1))
if child_plan_ok "$TR2197_OUT" "$TR2197_RC" '^PASS:' '^FAIL:'; then
    PASS=$((PASS + 1)); echo "  PASS: failed test runs preserve summaries and machine-readable output"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: test-runner failure output: $CHILD_PLAN_ERROR"
fi
printf '%s\n' "$TR2197_OUT" | sed 's/^/  /'
unset TR2197_OUT TR2197_RC
echo ""
