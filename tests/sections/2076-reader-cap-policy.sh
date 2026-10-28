echo "[2076] Shared reader cap policy and raised-cap replay (#2076)"
READER_CAP_OUT=$(EIGS="$EIGS" bash "$TESTS_DIR/test_reader_caps_2076.sh" 2>&1); READER_CAP_RC=$?
READER_CAP_PASS=$(printf '%s\n' "$READER_CAP_OUT" | grep -c '^PASS:' || true)
READER_CAP_FAIL=$(printf '%s\n' "$READER_CAP_OUT" | grep -c '^FAIL:' || true)
TOTAL=$((TOTAL + READER_CAP_PASS + READER_CAP_FAIL))
PASS=$((PASS + READER_CAP_PASS))
FAIL=$((FAIL + READER_CAP_FAIL))
if [ "$READER_CAP_RC" -ne 0 ] || [ "$READER_CAP_FAIL" -ne 0 ] || [ "$READER_CAP_PASS" -ne 10 ]; then
    FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1))
    echo "  FAIL: reader cap child contract (rc=$READER_CAP_RC, pass=$READER_CAP_PASS, fail=$READER_CAP_FAIL)"
    printf '%s\n' "$READER_CAP_OUT" | sed 's/^/      /'
else
    echo "  PASS: all $READER_CAP_PASS reader cap checks"
fi
echo ""
