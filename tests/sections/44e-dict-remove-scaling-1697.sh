echo "[44e] Ordered, amortized-O(1) dict removal (#1697)"
for tier in "EIGS_JIT_OFF=1" "" "EIGS_JIT_OSR_THRESHOLD=1"; do
    DR_OUTPUT=$(env $tier ./eigenscript "$TESTS_DIR/test_dict_order_1697.eigs" 2>&1); DR_RC=$?
    TOTAL=$((TOTAL + 1))
    if rc_ok "$DR_RC" "$DR_OUTPUT" && printf '%s\n' "$DR_OUTPUT" | grep -q '^Tests: 11 | Pass: 11 | Fail: 0$'; then
        PASS=$((PASS + 1)); echo "  PASS: ${tier:-default}: order, comparison, compaction, and reuse"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: ${tier:-default}: dict semantics rc=$DR_RC"; printf '%s\n' "$DR_OUTPUT" | eigs_failure_output
    fi
done

# With N=450,000 the old shift-and-rebuild implementation requires roughly
# 101 billion survivor moves (>10x the 180-second ASan lane bound), while the
# amortized implementation performs O(N) work and was calibrated below 18s
# (<1/10 of that bound).  Use the suite's portable timeout selection.
TOTAL=$((TOTAL + 1))
DR_OUTPUT=$($EIGS_TMO ./eigenscript "$TESTS_DIR/test_dict_remove_scaling.eigs" 2>&1); DR_RC=$?
if rc_ok "$DR_RC" "$DR_OUTPUT" && printf '%s\n' "$DR_OUTPUT" | grep -q '^Tests: 1 | Pass: 1 | Fail: 0$'; then
    PASS=$((PASS + 1)); echo "  PASS: 450,000-key removal finishes inside the margined suite bound"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: scaling gate rc=$DR_RC"; printf '%s\n' "$DR_OUTPUT" | eigs_failure_output
fi
unset DR_OUTPUT DR_RC
