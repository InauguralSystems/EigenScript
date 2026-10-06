echo "[0fb] Boolean type (#1637)"
check_eigs_suite "bool type: semantics 1-7, default tier" test_bool.eigs "All tests passed"
EIGS_JIT_OFF=1 check_eigs_suite "bool type: semantics 1-7, interpreter tier" test_bool.eigs "All tests passed"
# A bool never takes a numeric builtin's EIGS_STRICT=0 soft path (#1637).
EIGS_STRICT=0 check_eigs_suite "bool type: semantics 1-7, EIGS_STRICT=0" test_bool.eigs "All tests passed"
# Every numeric builtin, derived by probing the binary, refuses a bool in both
# strict modes (tests/test_bool_numeric.py). The tool prints its own verdict.
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
BOOL_NUM_OUT=$($EIGS_TMO python3 "$TESTS_DIR/test_bool_numeric.py" ./eigenscript 2>&1); BOOL_NUM_RC=$?
if [ "$BOOL_NUM_RC" = 0 ] && grep -q "^BOOL_NUMERIC: .* PASS$" <<< "$BOOL_NUM_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: numeric builtins refuse a bool in both strict modes ($(grep '^BOOL_NUMERIC' <<< "$BOOL_NUM_OUT"))"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: numeric builtins refuse a bool in both strict modes (rc=$BOOL_NUM_RC)"
    printf '%s\n' "$BOOL_NUM_OUT" | eigs_failure_output
fi
unset BOOL_NUM_OUT BOOL_NUM_RC
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
# Tape (#1637, format v6): a recorded bool replays as a bool, from the tape —
# the probed file is deleted between record and replay, so a live re-probe
# would answer false. A v5 header is refused (exit 3), never read as 1/0.
check_binary_fingerprint
BOOL_TP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/eigs_bool_tape.XXXXXX")
printf 'probe\n' > "$BOOL_TP_DIR/probe.txt"
printf 'x is file_exists of "%s"\nprint of [x, type of x, is_dir of "%s"]\n' \
    "$BOOL_TP_DIR/probe.txt" "$BOOL_TP_DIR/probe.txt" > "$BOOL_TP_DIR/p.eigs"
BOOL_TP_REC=$(EIGS_TRACE="$BOOL_TP_DIR/p.tape" $EIGS_TMO ./eigenscript "$BOOL_TP_DIR/p.eigs" </dev/null 2>&1)
rm -f "$BOOL_TP_DIR/probe.txt"
BOOL_TP_REP=$(EIGS_REPLAY="$BOOL_TP_DIR/p.tape" $EIGS_TMO ./eigenscript "$BOOL_TP_DIR/p.eigs" </dev/null 2>&1); BOOL_TP_RC=$?
TOTAL=$((TOTAL + 1))
if [ "$BOOL_TP_RC" = 0 ] && [ "$BOOL_TP_REC" = '[true, "bool", false]' ] &&
   [ "$BOOL_TP_REP" = "$BOOL_TP_REC" ] && grep -q '^N 0 file_exists=true$' "$BOOL_TP_DIR/p.tape"; then
    PASS=$((PASS + 1)); echo "  PASS: a recorded bool replays as a bool, from the tape"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: a recorded bool replays as a bool (rc=$BOOL_TP_RC rec='$BOOL_TP_REC' rep='$BOOL_TP_REP')"
fi
sed '1s/^V 6 /V 5 /' "$BOOL_TP_DIR/p.tape" > "$BOOL_TP_DIR/p5.tape"
BOOL_TP_OUT=$(EIGS_REPLAY="$BOOL_TP_DIR/p5.tape" $EIGS_TMO ./eigenscript "$BOOL_TP_DIR/p.eigs" </dev/null 2>&1); BOOL_TP_RC=$?
TOTAL=$((TOTAL + 1))
if [ "$BOOL_TP_RC" = 3 ] && grep -q "tape format v5, this binary reads v6" <<< "$BOOL_TP_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: a v5 (pre-bool) tape is refused with exit 3"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: a v5 (pre-bool) tape is refused with exit 3 (rc=$BOOL_TP_RC)"
    printf '%s\n' "$BOOL_TP_OUT" | eigs_failure_output
fi
rm -rf "$BOOL_TP_DIR"
unset BOOL_TP_DIR BOOL_TP_REC BOOL_TP_REP BOOL_TP_OUT BOOL_TP_RC
# Every public lib predicate, run on a battery plus true/false cases, answers
# with a bool (tests/test_bool_lib_predicates.py measures; it reads no code).
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
BOOL_LIB_OUT=$($EIGS_TMO python3 "$TESTS_DIR/test_bool_lib_predicates.py" ./eigenscript 2>&1); BOOL_LIB_RC=$?
if [ "$BOOL_LIB_RC" = 0 ] && grep -q "^BOOL_LIB_PREDICATES: .* PASS$" <<< "$BOOL_LIB_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: lib predicates answer bools ($(grep '^BOOL_LIB_PREDICATES' <<< "$BOOL_LIB_OUT"))"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: lib predicates answer bools (rc=$BOOL_LIB_RC)"
    printf '%s\n' "$BOOL_LIB_OUT" | eigs_failure_output
fi
unset BOOL_LIB_OUT BOOL_LIB_RC
