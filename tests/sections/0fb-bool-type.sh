echo "[0fb] Boolean type (#1637)"
check_eigs_suite "bool type: semantics 1-7, default tier" test_bool.eigs "All tests passed"
EIGS_JIT_OFF=1 check_eigs_suite "bool type: semantics 1-7, interpreter tier" test_bool.eigs "All tests passed"
# A bool never takes a builtin's EIGS_STRICT=0 soft path (#1637).
EIGS_STRICT=0 check_eigs_suite "bool type: semantics 1-7, EIGS_STRICT=0" test_bool.eigs "All tests passed"
# true and false in every argument slot of every builtin `--api --json` lists,
# and in the VM operand positions, raise in both strict modes unless the slot
# is on the reviewed any-value list (tests/test_bool_fuzz.sh; it prints its
# own verdict and examined counts).
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
BOOL_FZ_OUT=$(bash "$TESTS_DIR/test_bool_fuzz.sh" ./eigenscript 2>&1); BOOL_FZ_RC=$?
if [ "$BOOL_FZ_RC" = 0 ] && grep -q "^BOOL_FUZZ: examined=.* PASS$" <<< "$BOOL_FZ_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: a bool in any builtin slot or VM operand raises ($(grep '^BOOL_FUZZ: examined' <<< "$BOOL_FZ_OUT"))"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: a bool in any builtin slot or VM operand raises (rc=$BOOL_FZ_RC)"
    printf '%s\n' "$BOOL_FZ_OUT"
fi
unset BOOL_FZ_OUT BOOL_FZ_RC
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
# The class gate (#1637 round 3): every raw number read in src/*.c is typed
# or reviewed, no check-then-default read lacks a raising guard, and every
# builtin call passes the bool gate (tools/num_read_check.sh).
TOTAL=$((TOTAL + 1))
BOOL_NR_OUT=$(bash "$TESTS_DIR/../tools/num_read_check.sh" 2>&1); BOOL_NR_RC=$?
if [ "$BOOL_NR_RC" = 0 ] && grep -q '^num-read: PASS$' <<< "$BOOL_NR_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: number reads are typed ($(grep '^num-read: examined' <<< "$BOOL_NR_OUT"); $(grep '^bool-gate:' <<< "$BOOL_NR_OUT"))"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: number reads are typed (rc=$BOOL_NR_RC)"
    printf '%s\n' "$BOOL_NR_OUT"
fi
unset BOOL_NR_OUT BOOL_NR_RC
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
# Tamper: a v6 tape whose bool record was hand-edited to a number (and a
# number record edited to a bool) is refused with exit 3, naming the builtin,
# the record and the tape version -- never replayed as the other kind.
printf 'x is file_exists of "%s"\nr is random of null\nprint of [x, type of x, type of r]\n' \
    "$BOOL_TP_DIR/p.eigs" > "$BOOL_TP_DIR/t.eigs"
EIGS_TRACE="$BOOL_TP_DIR/t.tape" $EIGS_TMO ./eigenscript "$BOOL_TP_DIR/t.eigs" </dev/null >/dev/null 2>&1
sed 's/^\(N [0-9]* file_exists=\)true$/\11/' "$BOOL_TP_DIR/t.tape" > "$BOOL_TP_DIR/t1.tape"
sed 's/^\(N [0-9]* random=\).*$/\1true/' "$BOOL_TP_DIR/t.tape" > "$BOOL_TP_DIR/t2.tape"
for BOOL_TP_CASE in "t1:file_exists returns a bool, the tape holds a num" "t2:random returns a num, the tape holds a bool"; do
    TOTAL=$((TOTAL + 1))
    BOOL_TP_T=${BOOL_TP_CASE%%:*}; BOOL_TP_WANT=${BOOL_TP_CASE#*:}
    BOOL_TP_OUT=$(EIGS_REPLAY="$BOOL_TP_DIR/$BOOL_TP_T.tape" $EIGS_TMO ./eigenscript "$BOOL_TP_DIR/t.eigs" </dev/null 2>&1); BOOL_TP_RC=$?
    if ! cmp -s "$BOOL_TP_DIR/t.tape" "$BOOL_TP_DIR/$BOOL_TP_T.tape" && [ "$BOOL_TP_RC" = 3 ] &&
       grep -q "tape format v6 record 'N [0-9]* .*': $BOOL_TP_WANT; refusing to replay" <<< "$BOOL_TP_OUT"; then
        PASS=$((PASS + 1)); echo "  PASS: a tampered tape is refused: $BOOL_TP_WANT"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: a tampered tape is refused: $BOOL_TP_WANT (rc=$BOOL_TP_RC)"
        printf '%s\n' "$BOOL_TP_OUT" | eigs_failure_output
    fi
done
rm -rf "$BOOL_TP_DIR"
unset BOOL_TP_DIR BOOL_TP_REC BOOL_TP_REP BOOL_TP_OUT BOOL_TP_RC BOOL_TP_CASE BOOL_TP_T BOOL_TP_WANT
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
# lib/eigen.eigs's eigen_run agrees with the VM on every bool-producing form
# (tests/test_bool_meta_diff.py runs each snippet through both).
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
BOOL_META_OUT=$($EIGS_TMO python3 "$TESTS_DIR/test_bool_meta_diff.py" ./eigenscript 2>&1); BOOL_META_RC=$?
if [ "$BOOL_META_RC" = 0 ] && grep -q "^BOOL_META_DIFF: .* PASS$" <<< "$BOOL_META_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: eigen_run matches the VM on bools ($(grep '^BOOL_META_DIFF' <<< "$BOOL_META_OUT"))"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: eigen_run matches the VM on bools (rc=$BOOL_META_RC)"
    printf '%s\n' "$BOOL_META_OUT" | eigs_failure_output
fi
unset BOOL_META_OUT BOOL_META_RC
