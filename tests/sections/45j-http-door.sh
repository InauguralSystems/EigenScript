echo "[45j] The server reads every request through llhttp (#2370)"
DOOR_PROBE=$(mktemp "${TMPDIR:-/tmp}/eigs_door_probe_XXXXXX.eigs")
printf 'try:\n    http_route of ["GET", "/probe", "ok"]\ncatch e:\n    print of e.message\n' > "$DOOR_PROBE"
DOOR_OUT=$(./eigenscript "$DOOR_PROBE" 2>&1); DOOR_RC=$?
rm -f "$DOOR_PROBE"
# The parser is compiled in exactly the builds with the HTTP extension: a
# build without it has no llhttp_ symbol (an underscore before it on macOS).
DOOR_SYMS=$(nm ./eigenscript 2>&1); DOOR_NM_RC=$?
DOOR_LLHTTP=$(grep -cE ' _?llhttp_' <<< "$DOOR_SYMS")
if ! rc_ok "$DOOR_RC" "$DOOR_OUT"; then
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    echo "  FAIL: llhttp door capability probe (rc=$DOOR_RC)"
    printf '%s\n' "$DOOR_OUT"
elif grep -Eq 'undefined variable|capability unavailable' <<< "$DOOR_OUT"; then
    TOTAL=$((TOTAL + 1))
    if [ "$DOOR_NM_RC" -eq 0 ] && [ "$DOOR_LLHTTP" -eq 0 ] && grep -qE ' _?main$' <<< "$DOOR_SYMS"; then
        PASS=$((PASS + 1))
        echo "  PASS: a build without HTTP has no llhttp_ symbol"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: a build without HTTP has no llhttp_ symbol (nm rc=$DOOR_NM_RC, llhttp_ symbols=$DOOR_LLHTTP)"
    fi
    section_skip "binary built without HTTP"
else
    TOTAL=$((TOTAL + 1))
    DOOR_TEST=$(python3 "$TESTS_DIR/test_http_door.py" 2>&1); DOOR_TEST_RC=$?
    # D08 (peak resident size), D12 (time limits) and D15 (the budget) are
    # judged on the make http build; a sanitizer build, or one with no procfs
    # for D08, counts them as skipped.
    DOOR_WANT='HTTP_DOOR: 14 passed, 0 failed, 0 skipped'
    if grep -qaE '__asan_init|__tsan_init' ./eigenscript; then
        DOOR_WANT='HTTP_DOOR: 11 passed, 0 failed, 3 skipped'
    elif [ ! -r /proc/self/status ]; then
        DOOR_WANT='HTTP_DOOR: 13 passed, 0 failed, 1 skipped'
    fi
    if rc_ok "$DOOR_TEST_RC" "$DOOR_TEST" && grep -qxF "$DOOR_WANT" <<< "$DOOR_TEST" &&
       [ "$DOOR_LLHTTP" -gt 0 ]; then
        PASS=$((PASS + 1))
        echo "  PASS: llhttp door contract"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: llhttp door contract (rows=$DOOR_TEST_RC llhttp_ symbols=$DOOR_LLHTTP; wanted the line: $DOOR_WANT)"
    fi
    printf '%s\n' "$DOOR_TEST"
fi
unset DOOR_PROBE DOOR_OUT DOOR_RC DOOR_SYMS DOOR_NM_RC DOOR_LLHTTP DOOR_TEST DOOR_TEST_RC DOOR_WANT
echo ""
