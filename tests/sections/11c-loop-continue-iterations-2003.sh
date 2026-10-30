echo "[11c] Continue crosses the one while-loop iteration edge (#2003; interpreter/default/OSR)"
LC_EXPECTED='["mixed", 5]
["only-continue", 5]
["continue-stall", 107, "stalled"]
["continue-cap", false, true]'
for tier in "EIGS_JIT_OFF=1" "" "EIGS_JIT_OSR_THRESHOLD=1"; do
    LC_OUTPUT=$($EIGS_TMO env $tier ./eigenscript ../tests/test_loop_continue_iterations_2003.eigs 2>&1)
    LC_RC=$?
    TOTAL=$((TOTAL + 1))
    if rc_ok "$LC_RC" "$LC_OUTPUT" && [ "$LC_OUTPUT" = "$LC_EXPECTED" ]; then
        echo "  PASS: ${tier:-default}: continue count plus stall/cap guards"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${tier:-default}: continue skipped iteration accounting (rc=$LC_RC)"
        printf '%s\n' "$LC_OUTPUT" | eigs_failure_output
        FAIL=$((FAIL + 1))
    fi
done
unset LC_EXPECTED LC_OUTPUT LC_RC
echo ""
