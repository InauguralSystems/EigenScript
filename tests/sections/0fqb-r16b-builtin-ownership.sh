# #1758 R1.6b: raised reads must release heap operands and partial lists.
echo "[0fqb] R1.6b builtin ownership"
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
R16B_OUT=$(suite_program_run test_r16b_builtin_ownership.eigs $EIGS_TMO ./eigenscript "$TESTS_DIR/test_r16b_builtin_ownership.eigs" </dev/null 2>&1); R16B_RC=$?
if [ "$R16B_RC" -eq 0 ] && [ "$(lsan_classify_name "$R16B_OUT")" = none ] && grep -Fxq 'All tests passed.' <<< "$R16B_OUT"; then
    PASS=$((PASS + 1))
    echo "  PASS: R1.6b exact builtin reads and raises are leak-clean"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: R1.6b builtin ownership (rc=$R16B_RC)"
    printf '%s\n' "$R16B_OUT" | eigs_failure_output
fi
unset R16B_OUT R16B_RC
echo ""
