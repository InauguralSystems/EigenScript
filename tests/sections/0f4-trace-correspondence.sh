echo "[0f4] Stable host keys and causal spawned-worker correspondence (#1286)"
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
TRACE_CORRESPONDENCE_OUT=$(bash "$TESTS_DIR/test_trace_correspondence.sh" 2>&1); TRACE_CORRESPONDENCE_RC=$?
if rc_ok "$TRACE_CORRESPONDENCE_RC" "$TRACE_CORRESPONDENCE_OUT" && grep -qx 'trace correspondence: 31 passed, 0 failed (31 declared)' <<< "$TRACE_CORRESPONDENCE_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: stable host keys and causal worker correspondence"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: stream correspondence contract (rc=$TRACE_CORRESPONDENCE_RC)"
    printf '%s\n' "$TRACE_CORRESPONDENCE_OUT" | sed 's/^/      /'
fi
echo ""
