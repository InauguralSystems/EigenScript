# audio_noise on the trace tape (#1803); sourced by the suite fragment seam.
# The child records and replays across one-second boundaries, checks the
# chunked records and the seeded stream, and prints one row per check.
echo "[138] audio_noise on the trace tape (#1803)"
check_binary_fingerprint
AN_OUTPUT=$(bash "$TESTS_DIR/test_audio_noise_tape.sh" 2>&1); AN_RC=$?
TOTAL=$((TOTAL + 1))
if [ "$AN_RC" -eq 0 ] && rc_ok "$AN_RC" "$AN_OUTPUT" &&
    grep -q '^AUDIO_NOISE_TAPE: 9 passed, 0 failed$' <<< "$AN_OUTPUT"; then
    PASS=$((PASS + 1))
    echo "  PASS: audio_noise draws from the seeded stream and replays from the tape"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: audio_noise tape checks (rc=$AN_RC)"
fi
printf '%s\n' "$AN_OUTPUT"
unset AN_OUTPUT AN_RC
echo ""
