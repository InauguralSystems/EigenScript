echo "[138b] audio_open generator-safe rate limit (#1821)"
TOTAL=$((TOTAL + 1))
ARL_OUTPUT=$(SDL_AUDIODRIVER=dummy "$EIGS" "$TESTS_DIR/test_audio_rate_limit.eigs" 2>&1); ARL_RC=$?
if [ "$ARL_RC" -eq 0 ] && rc_ok "$ARL_RC" "$ARL_OUTPUT" &&
    printf '%s\n' "$ARL_OUTPUT" | grep -q '^Tests: 4 | Pass: 4 | Fail: 0$' &&
    printf '%s\n' "$ARL_OUTPUT" | grep -q '^All tests passed\.$'; then
    PASS=$((PASS + 1))
    echo "  PASS: over-limit rate refused and boundary accepted"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: audio rate boundary (rc=$ARL_RC)"
fi
printf '%s\n' "$ARL_OUTPUT"
unset ARL_OUTPUT ARL_RC
echo ""
