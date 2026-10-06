echo "[0fc] db parameters bind a bool as an SQL boolean (#1637)"
# Needs the libpq headers to build the server-db objects; no server is used.
# The build runs into build/server-db only, so the suite's src/eigenscript
# alias is not re-pointed.
if [ ! -f /usr/include/postgresql/libpq-fe.h ]; then
    section_skip "no libpq headers (/usr/include/postgresql/libpq-fe.h): the server-db objects cannot be built here"
else
    TOTAL=$((TOTAL + 1))
    DBP_BUILD=$(make --no-print-directory -C "$TESTS_DIR/.." build/server-db/test_db_params 2>&1); DBP_RC=$?
    DBP_OUT=""
    [ "$DBP_RC" = 0 ] && { DBP_OUT=$($EIGS_TMO "$TESTS_DIR/../build/server-db/test_db_params" 2>&1); DBP_RC=$?; }
    if rc_ok "$DBP_RC" "$DBP_OUT" && grep -qx 'db params: 7 passed, 0 failed (7 declared)' <<< "$DBP_OUT"; then
        PASS=$((PASS + 1)); echo "  PASS: a bool db parameter binds as SQL boolean text with OID 16"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: db parameter binding (rc=$DBP_RC)"
        printf '%s\n%s\n' "$DBP_BUILD" "$DBP_OUT" | sed 's/^/      /' | tail -30
    fi
    unset DBP_BUILD DBP_OUT DBP_RC
fi
echo ""
