echo "[70e1] Shared temporal history write boundary (#1575)"
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
HISTORY_BOUNDARY_OUT=$(EIGENSCRIPT=./eigenscript bash "$TESTS_DIR/test_trace_history_boundary.sh" 2>&1); HISTORY_BOUNDARY_RC=$?
if [ "$HISTORY_BOUNDARY_RC" -eq 0 ] && rc_ok "$HISTORY_BOUNDARY_RC" "$HISTORY_BOUNDARY_OUT" && grep -qx 'history boundary: 32 passed, 0 failed (32 declared)' <<< "$HISTORY_BOUNDARY_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: direct producers preserve history boundary and tape records"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: history boundary (rc=$HISTORY_BOUNDARY_RC)"
    printf '%s\n' "$HISTORY_BOUNDARY_OUT" | sed 's/^/      /'
fi
echo ""
