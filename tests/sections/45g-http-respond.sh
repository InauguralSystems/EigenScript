echo "[45g] Route status, headers and cookies (#2351)"
HR_PROBE=$(mktemp "${TMPDIR:-/tmp}/eigs_respond_probe_XXXXXX.eigs")
printf 'try:\n    http_route of ["GET", "/probe", "ok"]\ncatch e:\n    print of e.message\n' > "$HR_PROBE"
HR_OUT=$(./eigenscript "$HR_PROBE" 2>&1); HR_RC=$?
rm -f "$HR_PROBE"
if ! rc_ok "$HR_RC" "$HR_OUT"; then
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    echo "  FAIL: http_respond capability probe (rc=$HR_RC)"
    printf '%s\n' "$HR_OUT"
elif grep -Eq 'undefined variable|capability unavailable' <<< "$HR_OUT"; then
    section_skip "binary built without HTTP"
else
    TOTAL=$((TOTAL + 1))
    HR_TEST=$(python3 "$TESTS_DIR/test_http_respond.py" 2>&1); HR_TEST_RC=$?
    if rc_ok "$HR_RC" "$HR_OUT" && rc_ok "$HR_TEST_RC" "$HR_TEST" &&
       grep -qxF 'HTTP_RESPOND: 23 passed, 0 failed' <<< "$HR_TEST"; then
        PASS=$((PASS + 1))
        echo "  PASS: http_respond contract"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: http_respond contract (probe=$HR_RC rows=$HR_TEST_RC)"
        printf '%s\n' "$HR_OUT"
    fi
    printf '%s\n' "$HR_TEST"
fi
unset HR_PROBE HR_OUT HR_RC HR_TEST HR_TEST_RC
echo ""
