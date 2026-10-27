echo "[70e6] Observer snapshot safety and closure ownership (#1992)"
TOTAL=$((TOTAL + 1))
OSF2_OUTPUT=$(sh "$TESTS_DIR/test_observer_snapshot_fix2.sh" "$EIGS" 2>&1); OSF2_RC=$?
if [ "$OSF2_RC" -eq 0 ] && [ "$OSF2_OUTPUT" = "observer-snapshot-fix2-ok" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: bounded snapshots are non-raising, alias-safe, and leak-free"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: observer snapshot fix2 regression (rc=$OSF2_RC)"
    printf '%s\n' "$OSF2_OUTPUT"
fi
