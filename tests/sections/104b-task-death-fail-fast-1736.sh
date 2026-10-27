# [104b] #1736: what an uncaught error in a cooperative task does to the
# program — the rule table in docs/CONCURRENCY.md ("When a task dies of an
# uncaught error"). The line is `detached`: a task id is a plain number, so
# the runtime can never know a JOINABLE task won't be joined, and task_detach
# is the one point where it knows no join can ever see the failure.
#   row 1  a DETACHED task dies          -> stop at main's next scheduling
#                                           point, or at the exit drain; rc 1
#   row 2  a task dies, THEN is detached -> stop at that task_detach; rc 1
#   row 3  a JOINABLE task dies          -> main continues (#493): a later
#                                           try: task_join recovers (rc 0);
#                                           never joined, rc 1 — the never-
#                                           joined half is check_task_exit
#                                           task_exit_unjoined_death.eigs [104]
#   row 4  an OS THREAD, never joined    -> main completes; rc 1 (#1112) — the
#                                           check is check_thread_exit
#                                           thread_exit_unjoined_death.eigs [103b]
#   row 5  an OS THREAD, JOINED          -> thread_join raises the worker's error
#                                           at the join (#1745): main continues
#                                           past a caught join, rc 0 (observed)
# Every program runs to a verdict on its exit status, on lines that MUST
# print and on lines that must NOT (the stop is what keeps them unprinted),
# and is refused on any sanitizer diagnostic (the check_task_exit
# convention: the stop paths release main's parked slice early, and the ASan
# lane is where a leak or double release there would show).
echo "[104b] Task death: a detached task's uncaught error stops the program (#1736)"

# ff1736_check NAME FILE WANT_RC MARKER... — a MARKER is +TEXT (must appear)
# or -TEXT (must not appear), matched as a fixed string.
ff1736_check() {
    local name="$1" file="$2" want_rc="$3" out rc m bad=""
    shift 3
    check_binary_fingerprint
    out=$($EIGS_TMO ./eigenscript "../tests/$file" </dev/null 2>&1); rc=$?
    TOTAL=$((TOTAL + 1))
    [ "$rc" -eq "$want_rc" ] || bad="rc=$rc, want $want_rc"
    for m in "$@"; do
        case "$m" in
            +*) grep -qF -- "${m#+}" <<< "$out" || bad="${bad:+$bad; }missing '${m#+}'" ;;
            -*) grep -qF -- "${m#-}" <<< "$out" && bad="${bad:+$bad; }printed '${m#-}'" ;;
            *)  bad="${bad:+$bad; }harness: marker '$m' has no +/- sign" ;;
        esac
    done
    grep -qE "Sanitizer|runtime error:" <<< "$out" && bad="${bad:+$bad; }sanitizer diagnostic"
    if [ -z "$bad" ]; then
        PASS=$((PASS + 1)); echo "  PASS: $name"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: $name ($bad)"
        sed 's/^/      /' <<< "$out"
    fi
}

# Row 1 — a DETACHED task dies of an uncaught error: fail fast.
ff1736_check "row 1: a detached task's death stops main at its task_yield" \
    task_exit_detached_death.eigs 1 \
    "+main continues" "+undefined variable 'missing'" "+at die (" "-MARK_END"
ff1736_check "row 1: main never yields — the stop lands in the exit drain" \
    task_exit_detached_drain.eigs 1 \
    "+MAIN_DONE 200000" "+at die (" "-AFTER_DRAIN_TASK"
ff1736_check "row 1: main parked inside a try — not catchable, still reported" \
    task_exit_detached_try.eigs 1 \
    "+undefined variable 'missing'" "-AFTER_YIELD" "-CAUGHT" "-MARK_END"
ff1736_check "row 1: main blocked in task_join on a healthy task — nothing else runs" \
    task_exit_detached_join.eigs 1 \
    "+MAIN_JOINING" "+at die (" "-SLOW_FINISHED" "-JOINED" "-MARK_END"
ff1736_check "row 1: a task that detached itself, then died" \
    task_exit_detached_self.eigs 1 \
    "+MAIN_AFTER_FIRST_YIELD" "+at selfdie (" "-MARK_END"

# Row 2 — a task dies, THEN is detached: stop at that task_detach call.
ff1736_check "row 2: task_detach of a dead task stops at the call" \
    task_exit_detach_dead.eigs 1 \
    "+BEFORE_DETACH" "+task_detach: task" "+detaching it would discard that error" \
    "-AFTER_DETACH" "-MARK_END"
ff1736_check "row 2: the stop is uncatchable from a nested evaluation under two trys" \
    task_exit_detach_dead_nested.eigs 1 \
    "+task_detach: task" "+at keyfn (" \
    "-NESTED_CAUGHT" "-NESTED_AFTER_DETACH" "-SORTED" "-OUTER_CAUGHT" "-MARK_END"
ff1736_check "row 2: a worker's task_detach stops the program, not just the worker" \
    task_exit_detach_dead_worker.eigs 1 \
    "+WORKER_BEFORE_DETACH" "+task_detach: task" "+at detacher (" \
    "-WORKER_CAUGHT" "-WORKER_AFTER_DETACH" "-OTHER_TASK_RAN" "-MAIN_AFTER_YIELD" "-MARK_END"
ff1736_check "row 2 boundary: a killed task and a join-observed death detach normally" \
    task_exit_detach_observed.eigs 0 \
    "+DETACH_KILLED 1" "+JOIN_CAUGHT undefined_name" "+DETACH_OBSERVED 1" "+MARK_END" \
    "-task_detach: task"

# Row 3 — a JOINABLE task dies: unchanged (#493).
ff1736_check "row 3: main continues past a joinable death; a later try: task_join recovers" \
    task_exit_join_later.eigs 0 \
    "+at die (" "+MAIN_CONTINUES" "+RECOVERED undefined_name" "+MARK_END"

# Rows 4 and 5 — an OS thread dies. Thread timing is not on the tape (#148),
# so a fail-fast stop here would land somewhere different on every run: the
# death never stops main. Main's own program order decides what it sees. A
# thread nothing joins fails the run at exit (row 4, #1112; pinned in [103b] by
# thread_exit_unjoined_death.eigs). A thread main joins raises its error AT the
# join (row 5, #1745), and a caught join counts as observed, so these two exit
# 0: the JOIN_RAISED / "MAIN_JOINED raised" line proves the raise reached main,
# and MAIN_AFTER_DEATH / MARK_END prove main went on past the death.
ff1736_check "row 5: a joined OS thread's death raises at the join; main continues" \
    task_exit_thread_death.eigs 0 \
    "+at w (" "+JOIN_RAISED undefined_name" "+MAIN_AFTER_DEATH" "+MARK_END"
ff1736_check "rows 1+5: a detached task's death stops only its own thread; the join raises it" \
    task_exit_thread_detached.eigs 0 \
    "+at inner_die (" "+MAIN_JOINED raised undefined_name" "+MARK_END" "-WORKER_AFTER_YIELD"

# Rows 1 and 2 on the trace tape. WHEN the worker dies is decided by a taped
# random_int, so only the tape can put the stop in the same place twice.
# Record, then replay (strict) while writing a second tape. The two runs must
# print byte-identical stdout+stderr and exit 1, the recording must hold N
# records (the replay was real), MARK_END must be absent, and both tapes must
# end on the same source line — the stop line itself: the worker's throw for
# row 1, main's task_detach for row 2.
# ff1736_tape NAME FILE STOP_TEXT — STOP_TEXT names the stop line in FILE.
ff1736_tape() {
    local name="$1" file="$2" stop_text="$3"
    local t1 t2 rec rep rrc prc nrec stop_line l1 l2 bad=""
    check_binary_fingerprint
    TOTAL=$((TOTAL + 1))
    t1=$(mktemp "${TMPDIR:-/tmp}/eigs_ff1736.XXXXXX") || { FAIL=$((FAIL + 1)); echo "  FAIL: $name (mktemp)"; return; }
    t2=$(mktemp "${TMPDIR:-/tmp}/eigs_ff1736.XXXXXX") || { rm -f "$t1"; FAIL=$((FAIL + 1)); echo "  FAIL: $name (mktemp)"; return; }
    rec=$(EIGS_TRACE="$t1" $EIGS_TMO ./eigenscript "../tests/$file" </dev/null 2>&1); rrc=$?
    rep=$(EIGS_REPLAY="$t1" EIGS_REPLAY_STRICT=1 EIGS_TRACE="$t2" \
          $EIGS_TMO ./eigenscript "../tests/$file" </dev/null 2>&1); prc=$?
    nrec=$(grep -c '^N ' "$t1")
    stop_line=$(P="$stop_text" awk 'index($0, ENVIRON["P"]) { print NR; exit }' "../tests/$file")
    l1=$(grep '^L ' "$t1" | tail -1); l2=$(grep '^L ' "$t2" | tail -1)
    rm -f "$t1" "$t2"
    [ "$rrc" -eq 1 ] || bad="record rc=$rrc, want 1"
    [ "$prc" -eq 1 ] || bad="${bad:+$bad; }replay rc=$prc, want 1"
    [ "$rec" = "$rep" ] || bad="${bad:+$bad; }replay output differs from the recording"
    [ "${nrec:-0}" -ge 1 ] || bad="${bad:+$bad; }the tape holds no N record"
    grep -qF MARK_END <<< "$rec" && bad="${bad:+$bad; }printed MARK_END"
    [ -n "$stop_line" ] || bad="${bad:+$bad; }harness: '$stop_text' not found in $file"
    [ "${l1##* }" = "$stop_line" ] || bad="${bad:+$bad; }recording ends on '$l1', want line $stop_line"
    [ "$l1" = "$l2" ] || bad="${bad:+$bad; }replay ends on '$l2', recording on '$l1'"
    if [ -z "$bad" ]; then
        PASS=$((PASS + 1)); echo "  PASS: $name (stop at line $stop_line, $nrec N records)"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: $name ($bad)"
        diff <(printf '%s\n' "$rec") <(printf '%s\n' "$rep") | head -20 | sed 's/^/      /'
        tail -6 <<< "$rec" | sed 's/^/      rec: /'
    fi
}
ff1736_tape "row 1 on the tape: record and replay stop at the same throw" \
    task_exit_detached_tape.eigs 'throw of f"rolled a six'
ff1736_tape "row 2 on the tape: record and replay stop at the same task_detach" \
    task_exit_detach_dead_tape.eigs 'task_detach of t'
unset -f ff1736_check ff1736_tape
echo ""
