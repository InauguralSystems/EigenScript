#!/bin/bash
# #846: the scheduler trace is a PURE READER of the schedule and derives from
# it, not from the tape. Three claims, each asserted mechanically:
#   1. Purity — arming the trace (EIGS_TASK_TRACE=1) leaves stdout, stderr and
#      the exit code of a task program byte-identical, for every task example
#      and task program in the tree (seeded, virtual-time, mailbox, OSR, and
#      the six error-path programs: deadlock, kill, uncaught/detached death) —
#      the error paths matter because kill-release and the #509 deadlock
#      re-enqueue are causes only they reach.
#   2. Replay — a tape recorded with the trace armed replays (EIGS_REPLAY) to
#      the identical printed trace, JIT on and EIGS_JIT_OFF=1.
#   3. Not a tape record — the tape's N-record count is the same whether the
#      trace is armed or not (the probe consumes `random`, so the count is
#      nonzero and "unchanged" is a real comparison, not 0 == 0), no `N`
#      record in the tape read back names the trace or a cause, and
#      EIGS_REPLAY_STRICT=1 (a desynced nondet stream is fatal there)
#      reproduces the run and the trace unchanged.
# Runs with cwd src/ (the runner's convention); no bare `timeout`.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$TESTS_DIR/.." && pwd)/src"
EIGS="$SRC_DIR/eigenscript"
PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }
TMP=$(mktemp -d -t eigs_schedtrace.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
cd "$SRC_DIR" || { echo "  FAIL: cannot cd to $SRC_DIR"; exit 1; }

# ---- 1. purity across whole programs ----
run_to() {   # $1 = out-prefix, then env assignments + program
    local pre="$1"; shift
    env "$@" </dev/null >"$pre.out" 2>"$pre.err"; echo $? >"$pre.rc"
}
for prog in ../examples/task_pipeline.eigs ../examples/task_virtual_time.eigs \
            ../examples/task_seeded_schedule.eigs ../tests/test_tasks.eigs \
            ../tests/test_task_sleep_order.eigs ../tests/test_task_osr.eigs \
            ../tests/task_deadlock.eigs ../tests/task_deadlock_worker_try.eigs \
            ../tests/task_exit_killed.eigs ../tests/task_exit_join_catch.eigs \
            ../tests/task_exit_unjoined_death.eigs ../tests/task_exit_detached_death.eigs; do
    name=$(basename "$prog")
    run_to "$TMP/off" EIGS_TASK_TRACE=0 ./eigenscript "$prog"
    run_to "$TMP/on"  EIGS_TASK_TRACE=1 ./eigenscript "$prog"
    if cmp -s "$TMP/off.out" "$TMP/on.out" && cmp -s "$TMP/off.err" "$TMP/on.err" \
       && cmp -s "$TMP/off.rc" "$TMP/on.rc" \
       && { [ -s "$TMP/off.out" ] || [ -s "$TMP/off.err" ]; }; then
        ok "purity: $name byte-identical with the trace armed (rc $(cat "$TMP/on.rc"))"
    else
        fail "purity: $name diverged with the trace armed" "rc off=$(cat "$TMP/off.rc") on=$(cat "$TMP/on.rc"); $(diff "$TMP/off.out" "$TMP/on.out" | head -3 | tr '\n' ' ')"
    fi
done

# ---- 2. replay reproduces the trace; 3. the tape gains no N records ----
PROBE=../tests/task_sched_trace_probe.eigs
for tier in "jit-on" "jit-off"; do
    if [ "$tier" = "jit-off" ]; then JOFF=1; else JOFF=0; fi
    TAPE_ON="$TMP/on_$tier.tape"; TAPE_OFF="$TMP/off_$tier.tape"
    REC=$(EIGS_JIT_OFF=$JOFF EIGS_TASK_TRACE=1 EIGS_TRACE="$TAPE_ON" ./eigenscript "$PROBE" </dev/null 2>&1); REC_RC=$?
    REP=$(EIGS_JIT_OFF=$JOFF EIGS_TASK_TRACE=1 EIGS_REPLAY="$TAPE_ON" ./eigenscript "$PROBE" </dev/null 2>&1); REP_RC=$?
    EIGS_JIT_OFF=$JOFF EIGS_TASK_TRACE=0 EIGS_TRACE="$TAPE_OFF" ./eigenscript "$PROBE" </dev/null >/dev/null 2>&1
    N_ON=$(grep -c '^N ' "$TAPE_ON" 2>/dev/null); N_OFF=$(grep -c '^N ' "$TAPE_OFF" 2>/dev/null)
    ENTRIES=$(printf '%s\n' "$REC" | grep -c ' task=')
    # The trace must actually be there (10 resumes for this program) and carry
    # a wake at virtual tick 30 — a replay that reproduced an EMPTY trace would
    # otherwise pass the equality below.
    if [ "$REC_RC" = "0" ] && [ "$REP_RC" = "0" ] && [ "$REC" = "$REP" ] \
       && [ "$ENTRIES" = "10" ] && printf '%s\n' "$REC" | grep -q '^8 t=30 task=[0-9]* sleep-wake$'; then
        ok "replay ($tier): recorded and replayed traces are byte-identical ($ENTRIES entries)"
    else
        fail "replay ($tier): trace diverged under EIGS_REPLAY" "rc $REC_RC/$REP_RC entries=$ENTRIES; $(diff <(printf '%s\n' "$REC") <(printf '%s\n' "$REP") | head -3 | tr '\n' ' ')"
    fi
    if [ -n "$N_ON" ] && [ "$N_ON" -gt 0 ] && [ "$N_ON" = "$N_OFF" ]; then
        ok "tape ($tier): arming the trace adds no N records ($N_ON armed, $N_OFF unarmed)"
    else
        fail "tape ($tier): N-record count changed with the trace armed" "armed=$N_ON unarmed=$N_OFF"
    fi
    # No trace entry is ON the tape either. Only `N` records feed replay
    # substitution, so that is the set to inspect: read the tape back and
    # assert no N record names the trace or carries a cause string. (`A`
    # records legitimately hold the program's own `e` binding — the history
    # it already READ — which is an assignment delta, not a replay source.)
    N_LINES=$(grep '^N ' "$TAPE_ON" 2>/dev/null)
    if ! printf '%s
' "$N_LINES" | grep -qi 'sched_trace\|sleep-wake\|join-release'; then
        ok "tape ($tier): no N record names the trace or a cause ($N_ON N record(s): $(printf '%s' "$N_LINES" | cut -d= -f1 | tr '
' ' '))"
    else
        fail "tape ($tier): an N record carries trace payload" "$(printf '%s
' "$N_LINES" | grep -i 'sched_trace\|sleep-wake\|join-release' | head -2 | tr '
' ' ')"
    fi
    # Strict replay: a tape whose nondet stream had desynced (an extra or
    # missing record) is fatal under EIGS_REPLAY_STRICT, not silently absorbed.
    STRICT=$(EIGS_JIT_OFF=$JOFF EIGS_TASK_TRACE=1 EIGS_REPLAY_STRICT=1 EIGS_REPLAY="$TAPE_ON" ./eigenscript "$PROBE" </dev/null 2>&1); STRICT_RC=$?
    if [ "$STRICT_RC" = "0" ] && [ "$STRICT" = "$REC" ]; then
        ok "strict replay ($tier): EIGS_REPLAY_STRICT=1 reproduces the run and the trace"
    else
        fail "strict replay ($tier): strict mode diverged" "rc=$STRICT_RC; $(diff <(printf '%s\n' "$REC") <(printf '%s\n' "$STRICT") | head -3 | tr '\n' ' ')"
    fi
done

echo "SCHEDTRACE: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
