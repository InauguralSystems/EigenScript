echo "[104ze] Phase 2 Q7 geometry pixels (#1758)"
# Real pixels need SDL2. Where it is absent (the macOS runner), the test prints SKIP and exits 0,
# like [132]'s containment oracle; the exact geometry is still proven without SDL by
# gate.N5.q7-readers (tests/phase2/q7_readers.c).
check_binary_fingerprint
Q7P_OUT=$(suite_program_run test_phase2_gfx_q7.eigs $EIGS_TMO ./eigenscript ../tests/test_phase2_gfx_q7.eigs </dev/null 2>&1); Q7P_RC=$?
if rc_ok "$Q7P_RC" "$Q7P_OUT" && echo "$Q7P_OUT" | grep -q "All tests passed"; then
    TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
    echo "  PASS: whole-shape clipping and framebuffer source mapping"
elif [ "$Q7P_RC" = 0 ] && echo "$Q7P_OUT" | grep -q "^SKIP:"; then
    section_skip "$(echo "$Q7P_OUT" | grep "^SKIP:" | head -1)"
else
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    echo "  FAIL: whole-shape clipping and framebuffer source mapping (rc=$Q7P_RC)"
    printf '%s\n' "$Q7P_OUT" | eigs_failure_output
fi
echo ""
