echo "[15k] Runtime source locations (#1651)"
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
LOC_OUT=$(bash "$TESTS_DIR/test_issue_1651.sh" ./eigenscript 2>&1); LOC_RC=$?
if [ "$LOC_RC" = 0 ] && grep -q '^issue-1651: 10 passed, 0 failed$' <<< "$LOC_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: runtime errors identify every source location"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: runtime errors identify every source location (rc=$LOC_RC)"
    printf '%s\n' "$LOC_OUT"
fi
unset LOC_OUT LOC_RC
