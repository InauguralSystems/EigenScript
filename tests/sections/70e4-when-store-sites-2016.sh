echo "[70e4] User-binding store-site tier parity (#2016 fix round 1)"
WS_EXPECTED='[1, 2, 2, 2, 1, 2, [10, 1001]]'
WS_BASELINE=''
for tier in "EIGS_JIT_OFF=1" "" "EIGS_JIT_OSR_THRESHOLD=1"; do
    WS_OUTPUT=$(env $tier "$EIGS" "$EIGS_TEST_DIR/test_when_store_sites_2016.eigs" 2>&1)
    WS_RC=$?
    TOTAL=$((TOTAL + 1))
    if rc_ok "$WS_RC" "$WS_OUTPUT" && [ "$WS_OUTPUT" = "$WS_EXPECTED" ]; then
        if [ -z "$WS_BASELINE" ]; then WS_BASELINE=$WS_OUTPUT; fi
        if [ "$WS_OUTPUT" = "$WS_BASELINE" ]; then
            PASS=$((PASS + 1)); echo "  PASS: ${tier:-default}: all user-binding stores agree"
        else
            FAIL=$((FAIL + 1)); echo "  FAIL: ${tier:-default}: differs from interpreter"
        fi
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: ${tier:-default}: store counts (rc=$WS_RC)"
        printf '%s\n' "$WS_OUTPUT" | eigs_failure_output
    fi
done
unset WS_EXPECTED WS_BASELINE WS_OUTPUT WS_RC
echo ""
