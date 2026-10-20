# #1171: a call never uses a function value that a rebind of the same
# module-level binding has freed. Two checks, each rc 0, strictly leak-clean
# (the reader now takes a counted reference inside the rebind's hold, and a
# call keeps its callee until the frame holds the chunk: a leak here is a
# reference one of those no longer releases), and its exact PASS line.
#   rebind_call_race.eigs  threads call while other threads rebind (and
#                          reload a module); the cross-thread race itself is
#                          only VISIBLE to ThreadSanitizer, where
#                          tests/test_tsan.sh runs it as a zero-report row.
#   rebind_call_self.eigs  one thread: the callee's own argument reloads the
#                          module that defines it; deterministic under ASan.
echo "[0fo] Rebind vs call on a shared binding (#1171)"
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
RBC_OUTPUT=$(suite_program_run rebind_call_race.eigs $EIGS_TMO ./eigenscript "$TESTS_DIR/rebind_call_race.eigs" </dev/null 2>&1); RBC_RC=$?
if [ "$RBC_RC" -eq 0 ] &&
   [ "$(lsan_classify_name "$RBC_OUTPUT")" = none ] &&
   grep -Fxq 'rebind call race: PASS' <<< "$RBC_OUTPUT"; then
    PASS=$((PASS + 1))
    echo "  PASS: 3 caller workers + main call while 2 workers rebind and reload; totals conserved (leak-clean)"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: rebind vs call race (rc=$RBC_RC — must exit 0, leak-clean, with the PASS line)"
    printf '%s\n' "$RBC_OUTPUT" | eigs_failure_output
fi
TOTAL=$((TOTAL + 1))
RBS_OUTPUT=$(suite_program_run rebind_call_self.eigs $EIGS_TMO ./eigenscript "$TESTS_DIR/rebind_call_self.eigs" </dev/null 2>&1); RBS_RC=$?
if [ "$RBS_RC" -eq 0 ] &&
   [ "$(lsan_classify_name "$RBS_OUTPUT")" = none ] &&
   grep -Fxq 'rebind self call: PASS' <<< "$RBS_OUTPUT"; then
    PASS=$((PASS + 1))
    echo "  PASS: a call holds its callee until the frame holds its chunk (leak-clean)"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: rebind self call (rc=$RBS_RC — must exit 0, leak-clean, with the PASS line)"
    printf '%s\n' "$RBS_OUTPUT" | eigs_failure_output
fi
echo ""
