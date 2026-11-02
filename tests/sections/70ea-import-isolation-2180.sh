echo "[70ea] Imported modules are isolated from importer globals (#2180)"
IM2180_OUT=$(EIGS="$EIGS" bash "$TESTS_DIR/test_import_isolation_2180.sh" 2>&1); IM2180_RC=$?
TOTAL=$((TOTAL + 1))
if child_plan_ok "$IM2180_OUT" "$IM2180_RC" '^PASS:' '^FAIL:'; then
    PASS=$((PASS + 1)); echo "  PASS: VM, JIT and OSR enforce isolated imports; controls pass"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: import isolation checks: $CHILD_PLAN_ERROR"
fi
printf '%s\n' "$IM2180_OUT" | sed 's/^/  /'
unset IM2180_OUT IM2180_RC
