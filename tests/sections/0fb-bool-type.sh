echo "[0fb] Boolean type (#1637)"
check_eigs_suite "bool type: semantics 1-7, default tier" test_bool.eigs "All tests passed"
EIGS_JIT_OFF=1 check_eigs_suite "bool type: semantics 1-7, interpreter tier" test_bool.eigs "All tests passed"
# Forced JIT: every chunk compiles on first entry and every loop OSRs at once,
# so the comparison/NOT/JUMP_IF bool emitters run. A row that compiled nothing
# measured the interpreter, so it must also show compiled=N>0.
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
BOOL_JIT_OUT=$(EIGS_JIT_STATS=1 EIGS_JIT_ENTRY_THRESHOLD=1 EIGS_JIT_ITER_THRESHOLD=1 \
    EIGS_JIT_OSR_THRESHOLD=1 $EIGS_TMO ./eigenscript ../tests/test_bool.eigs </dev/null 2>&1)
BOOL_JIT_RC=$?
if rc_ok "$BOOL_JIT_RC" "$BOOL_JIT_OUT" && grep -q "All tests passed" <<< "$BOOL_JIT_OUT" &&
   [ "$(lar_jit_witness JIT "$BOOL_JIT_OUT")" = ok ]; then
    PASS=$((PASS + 1))
    echo "  PASS: bool type: semantics 1-7, forced-JIT tier (chunks compiled)"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: bool type: semantics 1-7, forced-JIT tier (rc=$BOOL_JIT_RC)"
    printf '%s\n' "$BOOL_JIT_OUT" | eigs_failure_output
fi
unset BOOL_JIT_OUT BOOL_JIT_RC
