echo "[1a7] sandbox source compile and execution budgets (#1579, #1403)"
run_test "sandbox source budgets" "$EIGS" "$TESTS_DIR/test_sandbox_source_budget.eigs"
PATH_OUT=$(EIGS="$EIGS" bash "$TESTS_DIR/test_sandbox_source_pathological.sh" 2>&1); PATH_RC=$?
if [ "$PATH_RC" -eq 0 ]; then
    PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); echo "  PASS: pathological source refused within compile budget"
else
    FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo "  FAIL: pathological source budget (rc=$PATH_RC)"
    printf '%s\n' "$PATH_OUT" | sed 's/^/      /'
fi
echo ""
