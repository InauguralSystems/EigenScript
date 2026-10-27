echo "[11b] Private-loop-counter opcodes are compiler-only (#1977; interpreter/default/OSR)"
# A sandbox descriptor that abuses OP_LOOP_EXIT_NAMED (101) must be refused by
# the verifier, not run: before the fix the standalone form double-freed the
# host's value (SIGABRT) and the nested form corrupted the host loop's own
# private counter ("loop counter depth 0 out of range"). Run across all three
# execution tiers because the host loop whose counter is the target is
# JIT/OSR-compilable.
NLV_EXPECTED='["standalone", false]
["host", 3, 3, false]'
for tier in "EIGS_JIT_OFF=1" "" "EIGS_JIT_OSR_THRESHOLD=1"; do
    NLV_OUTPUT=$(env $tier ./eigenscript ../tests/test_named_loop_verifier_1977.eigs 2>&1)
    NLV_RC=$?
    TOTAL=$((TOTAL + 1))
    if rc_ok "$NLV_RC" "$NLV_OUTPUT" && [ "$NLV_OUTPUT" = "$NLV_EXPECTED" ]; then
        echo "  PASS: ${tier:-default}: EXIT_NAMED descriptor refused, host frame intact"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${tier:-default}: named-loop verifier rejection or host corruption (rc=$NLV_RC)"
        printf '%s\n' "$NLV_OUTPUT" | eigs_failure_output
        FAIL=$((FAIL + 1))
    fi
done
unset NLV_EXPECTED NLV_OUTPUT NLV_RC
echo ""
