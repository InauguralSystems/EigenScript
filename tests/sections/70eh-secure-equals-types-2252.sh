echo "[70eh] secure_equals string-only contract (#2252)"
SECURE_EQUALS_OUT=$(EIGS="$EIGS" bash "$TESTS_DIR/test_issue_2252_secure_equals.sh" 2>&1); SECURE_EQUALS_RC=$?
TOTAL=$((TOTAL + 1))
if [ "$SECURE_EQUALS_RC" -eq 0 ] && rc_ok "$SECURE_EQUALS_RC" "$SECURE_EQUALS_OUT" &&
   printf '%s\n' "$SECURE_EQUALS_OUT" | grep -qxF 'ISSUE_2252: 3 passed, 0 failed'; then
    PASS=$((PASS + 1)); echo "  PASS: secure_equals accepts strings and rejects non-strings loudly"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: secure_equals string-only contract (rc=$SECURE_EQUALS_RC)"
fi
printf '%s\n' "$SECURE_EQUALS_OUT"
unset SECURE_EQUALS_OUT SECURE_EQUALS_RC
echo ""
