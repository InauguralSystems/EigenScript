echo "[18i] JIT hot diagnostics aggregate every OSR slot (#1606)"
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
OSR_SLOT_OUT=$(EIGS="$EIGENSCRIPT" bash "$TESTS_DIR/test_jit_osr_slot_diagnostics.sh" 2>&1)
OSR_SLOT_RC=$?
if rc_ok "$OSR_SLOT_RC" "$OSR_SLOT_OUT" &&
   grep -qx 'PASS: all OSR-slot cache rejections reconcile with the hot dump' <<< "$OSR_SLOT_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: every OSR-slot rejection is visible"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: OSR-slot diagnostic reconciliation (rc=$OSR_SLOT_RC)"
    printf '%s\n' "$OSR_SLOT_OUT" | sed 's/^/      /'
fi
unset OSR_SLOT_OUT OSR_SLOT_RC
echo ""
