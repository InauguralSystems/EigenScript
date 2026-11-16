echo "[45h] Request header fields and head boundary (#2373)"
QH_PROBE=$(mktemp "${TMPDIR:-/tmp}/eigs_reqheader_probe_XXXXXX.eigs")
printf 'try:\n    http_route of ["GET", "/probe", "ok"]\ncatch e:\n    print of e.message\n' > "$QH_PROBE"
QH_OUT=$(./eigenscript "$QH_PROBE" 2>&1); QH_RC=$?
rm -f "$QH_PROBE"
if ! rc_ok "$QH_RC" "$QH_OUT"; then
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    echo "  FAIL: http_request_header capability probe (rc=$QH_RC)"
    printf '%s\n' "$QH_OUT"
elif grep -Eq 'undefined variable|capability unavailable' <<< "$QH_OUT"; then
    section_skip "binary built without HTTP"
else
    TOTAL=$((TOTAL + 1))
    QH_TEST=$(python3 "$TESTS_DIR/test_http_request_header.py" 2>&1); QH_TEST_RC=$?
    # Row QH17 judges RSS and is skipped where RSS cannot be judged: with no
    # procfs, and on a sanitizer build. The two tests below are those of
    # tests/test_http_rss_growth.sh.
    QH_WANT='HTTP_REQUEST_HEADER: 17 passed, 0 failed, 0 skipped'
    if [ ! -r /proc/self/status ] || grep -qaE '__asan_init|__tsan_init' ./eigenscript; then
        QH_WANT='HTTP_REQUEST_HEADER: 16 passed, 0 failed, 1 skipped'
    fi
    if rc_ok "$QH_RC" "$QH_OUT" && rc_ok "$QH_TEST_RC" "$QH_TEST" &&
       grep -qxF "$QH_WANT" <<< "$QH_TEST"; then
        PASS=$((PASS + 1))
        echo "  PASS: http_request_header contract"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: http_request_header contract (probe=$QH_RC rows=$QH_TEST_RC; wanted the line: $QH_WANT)"
        printf '%s\n' "$QH_OUT"
    fi
    printf '%s\n' "$QH_TEST"
fi
unset QH_PROBE QH_OUT QH_RC QH_TEST QH_TEST_RC QH_WANT
echo ""
