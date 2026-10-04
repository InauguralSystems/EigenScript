echo "[0f9] Sandbox work accounting controls (#1403)"
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
WORK_OUT=$(bash "$TESTS_DIR/test_sandbox_work_budget.sh" 2>&1); WORK_RC=$?
if [[ "$WORK_RC" -eq 0 ]] && grep -qFx 'PASS: sandbox work budget (26 assertions)' <<< "$WORK_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: work arithmetic and ordinary VM accounting"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: sandbox work accounting (rc=$WORK_RC)"
    printf '%s\n' "$WORK_OUT" | sed 's/^/      /'
fi
echo ""
