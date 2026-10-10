echo "[0ff] Container slot API (#1665 B0)"
TOTAL=$((TOTAL + 1))
variant=release
if [ -e ../build/slot-rehearsal/eigenscript ] && [ ./eigenscript -ef ../build/slot-rehearsal/eigenscript ]; then
    variant=slot-rehearsal
elif [ -e ../build/asan/eigenscript ] && [ ./eigenscript -ef ../build/asan/eigenscript ]; then
    variant=asan
fi
if make -s -C .. SLOT_TEST_VARIANT="$variant" container-slot-test && \
   ../build/$variant/test_container_slots; then
    if [ "$variant" != slot-rehearsal ]; then
        PASS=$((PASS + 1))
    else
        set +e
        ../build/$variant/test_container_slots --escape-view >/tmp/eigs-slot-escape.$$ 2>&1
        rc=$?
        set -e
        if [ "$rc" -gt 128 ] && grep -q 'escaped numeric view' /tmp/eigs-slot-escape.$$; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1)); echo "  FAIL: escaped view plant rc=$rc"; cat /tmp/eigs-slot-escape.$$
        fi
        rm -f /tmp/eigs-slot-escape.$$
    fi
else
    FAIL=$((FAIL + 1)); echo "  FAIL: container slot API"
fi
echo ""
