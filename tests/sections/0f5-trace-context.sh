echo "[0f5] Owned replay contexts and explicit host session advance (#1286)"
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
TRACE_CONTEXT_OUT=$(bash "$TESTS_DIR/test_trace_context.sh" 2>&1); TRACE_CONTEXT_RC=$?
if rc_ok "$TRACE_CONTEXT_RC" "$TRACE_CONTEXT_OUT" && grep -qx 'trace context: 44 passed, 0 failed (44 declared)' <<< "$TRACE_CONTEXT_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: replay source/session ownership"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: stream context contract (rc=$TRACE_CONTEXT_RC)"
    printf '%s\n' "$TRACE_CONTEXT_OUT" | sed 's/^/      /'
fi
echo ""
