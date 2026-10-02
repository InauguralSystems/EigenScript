# #1417 uses the shared per-program mode so suite and differential agree.
echo "[42m] Non-finite buffer scalar reads (#1417)"
NF_OUTPUT=$(suite_program_run test_buffer_nonfinite_read.eigs ./eigenscript "$TESTS_DIR/test_buffer_nonfinite_read.eigs" 2>&1); NF_RC=$?
NF_EXPECTED=$(cat "$TESTS_DIR/test_buffer_nonfinite_read.out"); NF_EXPECTED_RC=$?
TOTAL=$((TOTAL + 1))
if [ "$NF_EXPECTED_RC" -eq 0 ] && [ -n "$NF_EXPECTED" ] && rc_ok "$NF_RC" "$NF_OUTPUT" && [ "$NF_OUTPUT" = "$NF_EXPECTED" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: non-finite buffer fixture matches expected output"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: non-finite buffer fixture (rc=$NF_RC)"
    printf '%s\n' "$NF_OUTPUT"
    echo "  Expected:"
    printf '%s\n' "$NF_EXPECTED"
fi
echo ""
