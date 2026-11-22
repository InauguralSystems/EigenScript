echo "[18k] R2.2 threshold agrees across execution tiers (STOP-R21-1)"
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
R21_THRESHOLD_OUT=$(EIGS="$EIGENSCRIPT" bash "$TESTS_DIR/test_phase2_r21_threshold.sh" 2>&1); R21_THRESHOLD_RC=$?
if child_plan_ok "$R21_THRESHOLD_OUT" "$R21_THRESHOLD_RC" '^PASS:' '^FAIL:'; then
    PASS=$((PASS + 1))
    echo "  PASS: interpreter, default JIT and OSR agree on the IEEE overflow result"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: R2.2 threshold agreement: $CHILD_PLAN_ERROR"
fi
printf '%s\n' "$R21_THRESHOLD_OUT" | sed 's/^/  /'
unset R21_THRESHOLD_OUT R21_THRESHOLD_RC
echo ""
