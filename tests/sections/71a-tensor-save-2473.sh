echo "[71a] tensor_save reports I/O failures (#2473)"
TS2473_OUT=$(EIGS="$EIGS" bash "$TESTS_DIR/test_tensor_save_2473.sh" 2>&1); TS2473_RC=$?
printf '%s\n' "$TS2473_OUT"
TOTAL=$((TOTAL + 1))
if [ "$TS2473_RC" -eq 0 ] && ! printf '%s\n' "$TS2473_OUT" | grep -q '^FAIL:'; then
    PASS=$((PASS + 1)); echo "  PASS: tensor_save I/O failure contract and compatible bytes"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: tensor_save I/O failure contract (rc=$TS2473_RC)"
fi
if printf '%s\n' "$TS2473_OUT" | grep -qx 'SKIP: no /dev/full on this platform'; then
    section_skip "no /dev/full on this platform"
fi
unset TS2473_OUT TS2473_RC
