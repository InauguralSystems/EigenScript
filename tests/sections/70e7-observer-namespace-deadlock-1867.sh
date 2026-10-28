echo "[70e7] Observer namespace snapshot liveness (#1867)"
TOTAL=$((TOTAL + 1))
OND_OUTPUT=$(suite_program_run observer_ns_deadlock.eigs $EIGS_TMO ./eigenscript \
    "$TESTS_DIR/observer_ns_deadlock.eigs" </dev/null 2>&1); OND_RC=$?
if [ "$OND_RC" -eq 0 ] &&
   grep -Fxq 'observer namespace deadlock: PASS' <<< "$OND_OUTPUT"; then
    PASS=$((PASS + 1))
    echo "  PASS: data-only module namespace snapshot completes after spawn"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: module namespace observer snapshot (rc=$OND_RC; timeout is a deadlock)"
    printf '%s\n' "$OND_OUTPUT" | eigs_failure_output
fi
