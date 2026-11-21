echo "[71b] tensor_save on a full device (#2473)"
if [ ! -e /dev/full ]; then
    section_skip "no /dev/full on this platform: the file-size limit of [71a] is the failed write that runs everywhere"
else
    TSF2473_OUT=$(EIGS="$EIGS" bash "$TESTS_DIR/test_tensor_save_2473.sh" --full-device 2>&1); TSF2473_RC=$?
    TOTAL=$((TOTAL + 1))
    if child_plan_ok "$TSF2473_OUT" "$TSF2473_RC" '^PASS:' '^FAIL:' && rc_ok "$TSF2473_RC" "$TSF2473_OUT"; then
        PASS=$((PASS + 1)); echo "  PASS: tensor_save raises io when the device is full"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: tensor_save on a full device: ${CHILD_PLAN_ERROR:-a sanitizer report in the output}"
    fi
    printf '%s\n' "$TSF2473_OUT" | sed 's/^/  /'
    unset TSF2473_OUT TSF2473_RC
fi
echo ""
