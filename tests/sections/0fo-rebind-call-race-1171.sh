# #1171: threads calling a module-level function while other threads rebind
# it must never call a freed closure. On this lane the program must finish,
# with its conserved totals asserted, and be strictly leak-clean (the reader
# now takes a counted reference inside the rebind's hold, so a leak here is a
# reference that hold no longer releases). The race itself is only VISIBLE to
# ThreadSanitizer: tests/test_tsan.sh runs this program as a zero-report row.
echo "[0fo] Rebind vs call on a shared binding (#1171)"
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
RBC_OUTPUT=$(suite_program_run rebind_call_race.eigs $EIGS_TMO ./eigenscript "$TESTS_DIR/rebind_call_race.eigs" </dev/null 2>&1); RBC_RC=$?
if [ "$RBC_RC" -eq 0 ] &&
   [ "$(lsan_classify_name "$RBC_OUTPUT")" = none ] &&
   grep -Fxq 'rebind call race: PASS' <<< "$RBC_OUTPUT"; then
    PASS=$((PASS + 1))
    echo "  PASS: 3 caller workers + main call while 2 workers rebind; totals conserved (leak-clean)"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: rebind vs call race (rc=$RBC_RC — must exit 0, leak-clean, with the PASS line)"
    printf '%s\n' "$RBC_OUTPUT" | eigs_failure_output
fi
echo ""
