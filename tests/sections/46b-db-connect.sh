echo "[46b] DATABASE_URL parsing and connection parameters (#2355)"
DC_PROBE=$(mktemp /tmp/eigs_db_connect_probe_XXXXXX.eigs)
printf 'print of (db_connect of null)\n' > "$DC_PROBE"
DC_OUT=$(env -u DATABASE_URL ./eigenscript "$DC_PROBE" 2>&1); DC_RC=$?
rm -f "$DC_PROBE"
if grep -Eq 'undefined variable|capability unavailable' <<< "$DC_OUT"; then
    section_skip "binary built without DB"
else
    TOTAL=$((TOTAL + 1))
    DC_TEST=$(python3 "$TESTS_DIR/test_db_connect.py" 2>&1); DC_TEST_RC=$?
    DC_WANT='DB_CONNECT: 8 passed, 0 failed, 0 skipped'
    [ -n "${DATABASE_URL:-}" ] || DC_WANT='DB_CONNECT: 1 passed, 0 failed, 7 skipped'
    if rc_ok "$DC_RC" "$DC_OUT" && rc_ok "$DC_TEST_RC" "$DC_TEST" &&
       grep -qxF "$DC_WANT" <<< "$DC_TEST"; then
        PASS=$((PASS + 1))
        echo "  PASS: DATABASE_URL contract"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: DATABASE_URL contract (probe=$DC_RC rows=$DC_TEST_RC)"
        printf '%s\n' "$DC_OUT"
    fi
    printf '%s\n' "$DC_TEST"
fi
unset DC_PROBE DC_OUT DC_RC DC_TEST DC_TEST_RC DC_WANT
echo ""
