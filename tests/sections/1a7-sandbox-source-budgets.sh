echo "[1a7] sandbox source compile and execution budgets (#1579, #1403)"
# run_test was defined nowhere, so this program never ran (hq#58); the pinned
# tally fails the section if an assert is dropped as well as if one fails.
check_eigs_suite "sandbox source budgets" test_sandbox_source_budget.eigs "^Tests: 19 | Pass: 19 | Fail: 0$"
PATH_OUT=$(EIGS="$EIGS" bash "$TESTS_DIR/test_sandbox_source_pathological.sh" 2>&1); PATH_RC=$?
if [ "$PATH_RC" -eq 0 ]; then
    PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo "  PASS: pathological source refused within compile budget"
else
    FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo "  FAIL: pathological source budget (rc=$PATH_RC)"
    printf '%s\n' "$PATH_OUT" | sed 's/^/      /'
fi
echo ""
