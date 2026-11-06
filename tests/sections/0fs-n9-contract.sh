# #1758 N9: Rust double-rounding and exact zero-divisor diagnostics.
echo "[0fs] N9 width arithmetic contract"
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
N9_OUT=$(suite_program_run test_n9_contract.eigs $EIGS_TMO ./eigenscript "$TESTS_DIR/test_n9_contract.eigs" </dev/null 2>&1); N9_RC=$?
if [ "$N9_RC" -eq 0 ] && [ "$(lsan_classify_name "$N9_OUT")" = none ] && grep -Fxq 'All tests passed.' <<< "$N9_OUT"; then
    PASS=$((PASS + 1))
    echo "  PASS: N9 exact builtin reads and raises are leak-clean"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: N9 width arithmetic contract (rc=$N9_RC)"
    printf '%s\n' "$N9_OUT" | eigs_failure_output
fi
unset N9_OUT N9_RC
echo ""
