echo "[45f] Static prefix registration and selection (#2356/#2357)"
SP_PROBE=$(mktemp /tmp/eigs_static_probe_XXXXXX.eigs)
printf 'print of (http_static of ["/probe", "."])\n' > "$SP_PROBE"
SP_OUT=$(./eigenscript "$SP_PROBE" 2>&1); SP_RC=$?
rm -f "$SP_PROBE"
if grep -Eq 'undefined variable|capability unavailable' <<< "$SP_OUT"; then
    section_skip "binary built without HTTP"
else
    TOTAL=$((TOTAL + 1))
    SP_TEST=$(python3 "$TESTS_DIR/test_static_prefixes.py" 2>&1); SP_TEST_RC=$?
    if rc_ok "$SP_RC" "$SP_OUT" && rc_ok "$SP_TEST_RC" "$SP_TEST" &&
       grep -qxF 'STATIC_PREFIXES: 15 passed, 0 failed' <<< "$SP_TEST"; then
        PASS=$((PASS + 1))
        echo "  PASS: static prefix contract"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: static prefix contract (probe=$SP_RC rows=$SP_TEST_RC)"
        printf '%s\n' "$SP_OUT"
    fi
    printf '%s\n' "$SP_TEST"
fi
unset SP_PROBE SP_OUT SP_RC SP_TEST SP_TEST_RC
echo ""
