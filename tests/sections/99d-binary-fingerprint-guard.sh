# [99d] Binary-fingerprint guard self-test (#681). Proves the runner aborts
# with the exact error message if src/eigenscript is replaced mid-suite.
echo "[99d] Binary-fingerprint guard self-test (#681)"
# #1708: prove the condition that made this control differ between a developer
# tree (where another session/Stop hook could make) and isolated CI.  Standard
# lock testing probes with an independent non-blocking acquisition; an exported
# EIGS_TREE_LOCK_HELD flag alone is not evidence that the lock is really owned.
TOTAL=$((TOTAL + 1))
sleep 5 & LOCK_PROBE_OWNER=$!
"$TESTS_DIR/../tools/tree_lock.sh" --try "$TESTS_DIR/.." "$LOCK_PROBE_OWNER" >/dev/null 2>&1
LOCK_PROBE_RC=$?
kill "$LOCK_PROBE_OWNER" 2>/dev/null
wait "$LOCK_PROBE_OWNER" 2>/dev/null
if [ "$LOCK_PROBE_RC" -eq 75 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: suite owns the build lock while the binary-guard control runs (#1708)"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: suite build lock was not busy during binary-guard control (rc=$LOCK_PROBE_RC; want 75)"
fi
TOTAL=$((TOTAL + 1))
if [ ! -f "$EIGS_BIN" ]; then
    # Round 6 counted this as a pass; the section's only check did not run.
    TOTAL=$((TOTAL - 1))
    section_skip "no binary to fingerprint"
else
    . "$TESTS_DIR/binary_swap.sh"
    SELFTEST_OUT=$(eigs_binary_swap_selftest 2>&1)
    SELFTEST_RC=$?
    RESTORE_OUT=$(python3 "$TESTS_DIR/test_binary_swap_restore.py" 2>&1)
    RESTORE_RC=$?
    if [ "$SELFTEST_RC" -eq 1 ] && [ "$RESTORE_RC" -eq 0 ] && printf '%s\n' "$SELFTEST_OUT" | grep -qF "ERROR: src/eigenscript changed during the run (rebuilt mid-suite) — results are invalid."; then
        PASS=$((PASS + 1))
        echo "  PASS: binary-fingerprint guard detected mid-run swap and aborted with the expected error"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: binary-fingerprint guard did not detect mid-run swap (rc=$SELFTEST_RC)"
        printf '%s\n' "$SELFTEST_OUT" "$RESTORE_OUT" | head -12 | sed 's/^/      /'
    fi
fi
echo ""
