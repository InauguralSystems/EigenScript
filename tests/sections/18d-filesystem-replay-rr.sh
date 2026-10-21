echo "[18d] Side-effect-free filesystem replay (#1885, #1890)"
RR_OUTPUT=$(bash "$TESTS_DIR/test_replay_filesystem_rr.sh" 2>&1); RR_RC=$?
TOTAL=$((TOTAL + 1))
if [ "$RR_RC" -eq 0 ] && rc_ok "$RR_RC" "$RR_OUTPUT" &&
   grep -q '^FILESYSTEM RR: 3 passed, 0 failed$' <<< "$RR_OUTPUT"; then
    PASS=$((PASS + 1)); echo "  PASS: filesystem reads and mutations replay from tape only"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: filesystem rr contract (rc=$RR_RC)"
fi
printf '%s\n' "$RR_OUTPUT"
unset RR_OUTPUT RR_RC
echo ""
