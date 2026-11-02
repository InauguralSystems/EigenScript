echo "[44i] Channel capacity and rendezvous (#1643)"
TOTAL=$((TOTAL + 1))
CC1643_OUTPUT=$(bash "$TESTS_DIR/test_channel_capacity.sh" 2>&1); CC1643_RC=$?
if [ "$CC1643_RC" -eq 0 ] &&
   [ "$(printf '%s\n' "$CC1643_OUTPUT" | grep -c '^PASS: ')" -eq 17 ] &&
   ! printf '%s\n' "$CC1643_OUTPUT" | grep -q '^FAIL: '; then
    PASS=$((PASS + 1))
    echo "  PASS: capacities, rendezvous completion and polling receive"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: channel capacity contract (rc=$CC1643_RC)"
    printf '%s\n' "$CC1643_OUTPUT"
fi
