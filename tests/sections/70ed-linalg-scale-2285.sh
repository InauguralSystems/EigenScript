echo "[70ed] Scale-aware linear algebra singularity (#2285)"
TOTAL=$((TOTAL + 1))
LINALG_2285_OUTPUT=$($EIGS_TMO "$EIGS" "$TESTS_DIR/test_issue_2285.eigs" 2>&1); LINALG_2285_RC=$?
if rc_ok "$LINALG_2285_RC" "$LINALG_2285_OUTPUT" &&
   grep -q '^Tests: 18 | Pass: 18 | Fail: 0$' <<< "$LINALG_2285_OUTPUT"; then
    PASS=$((PASS + 1))
    echo "  PASS: scaled nonsingular and roundoff-singular matrices are distinguished"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: linalg scale regression rc=$LINALG_2285_RC"
    printf '%s\n' "$LINALG_2285_OUTPUT" | eigs_failure_output
fi
unset LINALG_2285_OUTPUT LINALG_2285_RC
