echo "[42p] Strict byte-list conversion (#1590)"
SB_OUTPUT=$(bash "$TESTS_DIR/test_strict_byte_conversion.sh" 2>&1); SB_RC=$?
SB_PASS=$(printf '%s\n' "$SB_OUTPUT" | grep -c "  PASS:" || true)
SB_FAIL=$(printf '%s\n' "$SB_OUTPUT" | grep -c "  FAIL:" || true)
TOTAL=$((TOTAL + SB_PASS + SB_FAIL))
PASS=$((PASS + SB_PASS))
FAIL=$((FAIL + SB_FAIL))
printf '%s\n' "$SB_OUTPUT"
if ! rc_ok "$SB_RC" "$SB_OUTPUT" || { [ "$SB_PASS" -ne 12 ] && [ "$SB_PASS" -ne 23 ]; } || [ "$SB_FAIL" -ne 0 ]; then
    FAIL=$((FAIL + 1))
    TOTAL=$((TOTAL + 1))
    echo "  FAIL: strict byte-list conversion summary (rc=$SB_RC)"
fi
echo ""
