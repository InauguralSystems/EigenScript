echo "[11a] Per-loop published iteration count (#1906; interpreter/default/OSR)"
LI_EXPECTED='["normal", "normal", 3]
["stall", "stalled", 107]
["limit", false, 5]
["nested", 2]
["budget", false, 2, true]
["frame", true]
["recursive", true]'
for tier in "EIGS_JIT_OFF=1" "" "EIGS_JIT_OSR_THRESHOLD=1"; do
    LI_OUTPUT=$(env $tier ./eigenscript ../tests/test_loop_iterations_per_loop.eigs 2>&1)
    LI_RC=$?
    TOTAL=$((TOTAL + 1))
    if rc_ok "$LI_RC" "$LI_OUTPUT" && [ "$LI_OUTPUT" = "$LI_EXPECTED" ]; then
        echo "  PASS: ${tier:-default}: loop counts and fresh per-frame sandbox budgets"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${tier:-default}: per-loop counts or sandbox budget (rc=$LI_RC)"
        printf '%s\n' "$LI_OUTPUT" | eigs_failure_output
        FAIL=$((FAIL + 1))
    fi
done
unset LI_EXPECTED LI_OUTPUT LI_RC
echo ""
