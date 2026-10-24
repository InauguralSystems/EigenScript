# #1758 N4: integer/float floor division, floor modulo, compound targets,
# boxed-int success and raise ownership. Strictly leak-clean, as [87].
echo "[0fq] Floor division and modulo (#1758 N4)"
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
FLOOR_OUT=$(suite_program_run test_floor_division.eigs $EIGS_TMO ./eigenscript "$TESTS_DIR/test_floor_division.eigs" </dev/null 2>&1); FLOOR_RC=$?
if [ "$FLOOR_RC" -eq 0 ] && [ "$(lsan_classify_name "$FLOOR_OUT")" = none ] && grep -q '^All tests passed' <<< "$FLOOR_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: floor arithmetic and boxed ownership (leak-clean)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: floor arithmetic rc=$FLOOR_RC"
    printf '%s\n' "$FLOOR_OUT" | eigs_failure_output
fi
echo ""
