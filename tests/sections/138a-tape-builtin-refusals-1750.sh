echo "[138a] Recorded builtin argument refusals stay raises on strict replay (#1750)"
TBR_OUTPUT=$(EIGS="$EIGS" bash "$TESTS_DIR/test_issue_1750_tape_refusals.sh" 2>&1); TBR_RC=$?
TOTAL=$((TOTAL + 1))
if [ "$TBR_RC" -eq 0 ] && rc_ok "$TBR_RC" "$TBR_OUTPUT" &&
   grep -qxF 'ISSUE_1750: 1 passed, 0 failed' <<< "$TBR_OUTPUT"; then
    PASS=$((PASS + 1)); echo "  PASS: type refusals consume and record no nondeterministic value"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: taped builtin refusal replay (rc=$TBR_RC)"
fi
printf '%s\n' "$TBR_OUTPUT"
unset TBR_OUTPUT TBR_RC
echo ""
