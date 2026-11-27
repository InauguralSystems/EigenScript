echo "[45k] lib/auth reads the one Authorization field (#2374)"
AH_PROBE=$(mktemp "${TMPDIR:-/tmp}/eigs_auth_probe_XXXXXX.eigs")
printf 'try:\n    http_route of ["GET", "/probe", "ok"]\ncatch e:\n    print of e.message\n' > "$AH_PROBE"
AH_OUT=$(./eigenscript "$AH_PROBE" 2>&1); AH_RC=$?
rm -f "$AH_PROBE"
if ! rc_ok "$AH_RC" "$AH_OUT"; then
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    echo "  FAIL: lib/auth header capability probe (rc=$AH_RC)"
    printf '%s\n' "$AH_OUT"
elif grep -Eq 'undefined variable|capability unavailable' <<< "$AH_OUT"; then
    section_skip "binary built without HTTP"
else
    TOTAL=$((TOTAL + 1))
    AH_TEST=$(EIGS_BIN="$PWD/eigenscript" python3 "$TESTS_DIR/test_auth_header_2374.py" 2>&1); AH_TEST_RC=$?
    if rc_ok "$AH_TEST_RC" "$AH_TEST" &&
       grep -qxF 'AUTH_HEADER_2374: 12 passed, 0 failed, 0 skipped' <<< "$AH_TEST"; then
        PASS=$((PASS + 1))
        echo "  PASS: lib/auth Authorization rows over a socket"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: lib/auth Authorization rows over a socket (rc=$AH_TEST_RC)"
    fi
    printf '%s\n' "$AH_TEST" | sed 's/^  PASS:/    row ok:/; s/^  FAIL:/    row FAIL:/'
fi
unset AH_PROBE AH_OUT AH_RC AH_TEST AH_TEST_RC
echo ""
