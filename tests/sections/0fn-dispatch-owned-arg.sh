# #1838: an owned dispatch argument must be released after either binding
# path retains it. This regression is strictly leak-clean, like section [87].
echo "[0fn] Dispatch argument ownership"
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
DARG_OUTPUT=$(suite_program_run test_dispatch_owned_arg.eigs $EIGS_TMO ./eigenscript "$TESTS_DIR/test_dispatch_owned_arg.eigs" </dev/null 2>&1); DARG_RC=$?
if [ "$DARG_RC" -eq 0 ] &&
   [ "$(lsan_classify_name "$DARG_OUTPUT")" = none ] &&
   grep -Fxq 'dispatch owned args: PASS' <<< "$DARG_OUTPUT"; then
    PASS=$((PASS + 1))
    echo "  PASS: dispatch preserves owned arguments through fresh and recycled envs (leak-clean)"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: dispatch argument ownership (rc=$DARG_RC — must be leak-clean)"
    printf '%s\n' "$DARG_OUTPUT" | eigs_failure_output
fi
echo ""
