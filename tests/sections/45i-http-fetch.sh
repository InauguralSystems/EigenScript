echo "[45i] Outbound HTTP exchange and tape (#2375)"
HF_PROBE=$(mktemp "${TMPDIR:-/tmp}/eigs_fetch_probe_XXXXXX.eigs")
# An established builtin identifies the extension; losing only http_fetch
# must reach its contract rows instead of being mistaken for a missing profile.
printf 'try:\n    http_post of null\ncatch problem:\n    print of problem.message\n' > "$HF_PROBE"
HF_PROBE_OUT=$(./eigenscript "$HF_PROBE" 2>&1); HF_PROBE_RC=$?
rm -f "$HF_PROBE"
if ! rc_ok "$HF_PROBE_RC" "$HF_PROBE_OUT"; then
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    echo "  FAIL: HTTP capability probe (rc=$HF_PROBE_RC)"
    printf '%s\n' "$HF_PROBE_OUT"
elif grep -Eq 'undefined variable|capability unavailable' <<< "$HF_PROBE_OUT"; then
    section_skip "binary built without HTTP"
else
    TOTAL=$((TOTAL + 1))
    # 76 named rows include the whole-run TMPDIR check. The five /proc/loader
    # rows, two openssl rows and curl-8 header-NUL row have explicit skips.
    HF_SKIPS=0
    if [ "$(uname -s)" != Linux ]; then
        HF_SKIPS=$((HF_SKIPS + 5))
    elif [ ! -d /proc/self/task ]; then
        HF_SKIPS=$((HF_SKIPS + 2))
    fi
    if ! command -v openssl >/dev/null 2>&1; then HF_SKIPS=$((HF_SKIPS + 2)); fi
    # The release of the curl library the rows run against, asked of the
    # library itself (curl_version) by the names the runtime loads it by.
    HF_LIB_TEXT=$(python3 -c 'import sys; sys.path.insert(0,sys.argv[1]); from test_http_fetch import curl_version_text; print(curl_version_text())' "$TESTS_DIR" 2>&1)
    HF_LIB_RC=$?
    HF_LIB_MAJOR=
    if [ "$HF_LIB_RC" -eq 0 ]; then
        # The suite counts these words: a release line that held one would
        # be counted, so it is not printed and the section fails instead.
        if grep -Eq 'PASS|FAIL|SKIP' <<< "$HF_LIB_TEXT"; then HF_LIB_RC=3; HF_LIB_TEXT='(the text holds a word the suite counts)'
        else echo "HTTP_FETCH_LIBCURL: $HF_LIB_TEXT"; fi
        HF_LIB_MAJOR=$(sed -n 's/^libcurl\/\([0-9][0-9]*\)\..*/\1/p' <<< "$HF_LIB_TEXT")
        if [ -z "$HF_LIB_MAJOR" ]; then HF_LIB_RC=4; fi
    fi
    if [ "$HF_LIB_RC" -eq 0 ] && [ "$HF_LIB_MAJOR" -lt 8 ]; then HF_SKIPS=$((HF_SKIPS + 1)); fi
    HF_PASSES=$((76 - HF_SKIPS))
    HF_WANT="HTTP_FETCH: $HF_PASSES passed, 0 failed, $HF_SKIPS skipped"
    HF_TEST=$(python3 "$TESTS_DIR/test_http_fetch.py" 2>&1); HF_TEST_RC=$?
    if [ "$HF_LIB_RC" -eq 0 ] && rc_ok "$HF_TEST_RC" "$HF_TEST" && grep -qxF "$HF_WANT" <<< "$HF_TEST"; then
        PASS=$((PASS + 1))
        echo "  PASS: http_fetch contract"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: http_fetch contract (probe=$HF_PROBE_RC rows=$HF_TEST_RC; wanted: $HF_WANT)"
        printf '%s\n' "$HF_PROBE_OUT"
        if [ "$HF_LIB_RC" -ne 0 ]; then echo "  curl library release not read (code $HF_LIB_RC)"; printf '%s\n' "$HF_LIB_TEXT" | sed 's/^/    /'; fi
    fi
    printf '%s\n' "$HF_TEST"
fi
unset HF_PROBE HF_PROBE_OUT HF_PROBE_RC HF_SKIPS HF_LIB_TEXT HF_LIB_MAJOR HF_LIB_RC HF_PASSES HF_WANT HF_TEST HF_TEST_RC
echo ""
