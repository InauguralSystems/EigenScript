echo "[70e6] Observer snapshot safety and closure ownership (#1992)"
TOTAL=$((TOTAL + 1))
OSF2_OUTPUT=$(bash "$TESTS_DIR/test_observer_snapshot_fix2.sh" "$EIGS" 2>&1); OSF2_RC=$?
if [ "$OSF2_RC" -eq 0 ] && grep -qx 'observer-snapshot-fix2-ok' <<< "$OSF2_OUTPUT" &&
   [ "$(grep -c '^  PASS: observer fix2 ' <<< "$OSF2_OUTPUT")" -gt 0 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: bounded snapshots are non-raising, alias-safe, and leak-free"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: observer snapshot fix2 regression (rc=$OSF2_RC)"
    printf '%s\n' "$OSF2_OUTPUT"
fi

TOTAL=$((TOTAL + 1))
variant=release
if [ -e ../build/asan/eigenscript ] && [ ./eigenscript -ef ../build/asan/eigenscript ]; then
    variant=asan
fi
if make -s -C .. NUM_GUARD_VALUE_VARIANT="$variant" num-guard-value-test && \
   ../build/$variant/test_num_guard_value; then
    PASS=$((PASS + 1))
    echo "  PASS: pure scalar guard matches num_guard values without changing math flags"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: pure scalar guard diverges from num_guard values"
fi
