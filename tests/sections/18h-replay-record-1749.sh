echo "[18h] Recording a replay retains served external inputs (#1749)"
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
REPLAY_RECORD_OUT=$(EIGS="$EIGENSCRIPT" bash "$TESTS_DIR/test_replay_record.sh" 2>&1)
REPLAY_RECORD_RC=$?
if rc_ok "$REPLAY_RECORD_RC" "$REPLAY_RECORD_OUT" &&
   grep -qx 'PASS: replay while recording retains every served record byte-identically' <<< "$REPLAY_RECORD_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: replay/record tape is byte-identical"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: replay/record tape contract (rc=$REPLAY_RECORD_RC)"
    printf '%s\n' "$REPLAY_RECORD_OUT" | sed 's/^/      /'
fi
unset REPLAY_RECORD_OUT REPLAY_RECORD_RC
echo ""
