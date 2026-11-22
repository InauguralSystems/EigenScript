echo "[71a] tensor_save reports a failed open, write or close (#2473)"
TS2473_OUT=$(EIGS="$EIGS" bash "$TESTS_DIR/test_tensor_save_2473.sh" 2>&1); TS2473_RC=$?
TOTAL=$((TOTAL + 1))
if child_plan_ok "$TS2473_OUT" "$TS2473_RC" '^PASS:' '^FAIL:' && rc_ok "$TS2473_RC" "$TS2473_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: tensor_save raises io on a failed open or write and saves the same bytes"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: tensor_save I/O failures: ${CHILD_PLAN_ERROR:-a sanitizer report in the output}"
fi
printf '%s\n' "$TS2473_OUT" | sed 's/^/  /'
unset TS2473_OUT TS2473_RC
echo ""
