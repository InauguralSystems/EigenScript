#!/bin/bash
WERROR_FLAGS_FILE="$(dirname "$0")/../tools/werror_flags.txt"
. "$(dirname "$0")/../tools/read_werror_flags.sh" || exit 1
# ThreadSanitizer concurrency race gate (#401). Two claims, both mechanical:
#   1. the spawn/channel test slice is RACE-FREE (the #297 "TSan-clean" property,
#      previously only a code comment — now regression-gated), and
#   2. a deliberately-seeded race IS caught (so the gate can't rot into a
#      vacuous pass).
# Expects a TSan-built interpreter at src/eigenscript (`make tsan`). ThreadSanitizer
# needs ASLR off here, so every run goes through `setarch -R` (see CLAUDE.md).
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$TESTS_DIR/../src/eigenscript"
export TSAN_OPTIONS="halt_on_error=0 exitcode=0"
PASS=0; FAIL=0

# This is a capability of the binary under test, not of the runner.  main.c
# prints it from EIGS_JIT_ENABLED, the exact gate used by jit.c's emitter.
# setarch -R like every other run below: a TSan binary started with ASLR on can
# die before main ("FATAL: ThreadSanitizer: unexpected memory mapping"); on the
# dev box's kernel that was 19 of 20 bare runs and 0 of 20 under setarch -R.
BUILD_INFO=$(setarch -R "$EIGS" --build-info 2>&1)
JIT_BACKEND=$(printf '%s\n' "$BUILD_INFO" | awk -F= '$1 == "jit-backend" { print $2; exit }')
if [ -z "$JIT_BACKEND" ]; then
    echo "FAIL: binary supplied no jit-backend build-info witness"
    printf '%s\n' "$BUILD_INFO" | head -3 | sed 's/^/  /'
    exit 1
fi
# Anti-spread check: the established non-Apple Linux x86-64 lane must never
# turn loss of its backend into a skip.  uname identifies that required lane;
# it does not decide whether emitted-code assertions apply to this binary.
if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] && \
   [ "$JIT_BACKEND" = none ]; then
    echo "FAIL: non-Apple Linux x86-64 binary has no JIT backend ($JIT_BACKEND)"
    exit 1
fi

# Every run is timeout-bounded. TSan's warnings are emitted as they happen,
# so a killed run still yields its warning count.
TSAN_RUN_TIMEOUT=${TSAN_RUN_TIMEOUT:-120}
# Sets WARNINGS + LAST_RC as globals — deliberately NOT echo-and-capture:
# `w=$(fn)` would run fn in a subshell and the parent would never see
# LAST_RC, silently disabling the hang branch (caught by a planted hang).
WARNINGS=0
LAST_RC=0
RUN_OUTPUT=""
tsan_warnings() {
    local out
    if [ "${1##*/}" = "tsan_spawn_emitted_jit.eigs" ]; then
        out=$(timeout "$TSAN_RUN_TIMEOUT" setarch -R env EIGS_JIT_STATS=1 EIGS_JIT_HOT=1 "$EIGS" "$1" 2>&1)
    else
        out=$(timeout "$TSAN_RUN_TIMEOUT" setarch -R "$EIGS" "$1" 2>&1)
    fi
    LAST_RC=$?
    RUN_OUTPUT=$out
    WARNINGS=$(printf '%s\n' "$out" | grep -c "WARNING: ThreadSanitizer" || true)
}

# A failing row prints the report of the run that FAILED, whole: from its first
# WARNING through that report's SUMMARY line. Re-running a racy fixture to show
# its report usually comes back clean, so an intermittent race printed nothing:
# ARM64's loader_mt_define_result failed in merge group fb394e5e (2026-10-28)
# with "reported 1 ThreadSanitizer warning(s)" and no report at all.
tsan_report() {
    awk '/WARNING: ThreadSanitizer/ {f=1} f {print "      " $0} f && /^SUMMARY: ThreadSanitizer/ {exit}' | head -80
}

observer_shared_fold_rows() {
    echo "=== #1867 shared ObserverSlot folds must hold #607 ==="
    local fixtures="tsan_observer_shared_fold tsan_observer_sandbox_probe observer_ns_deadlock"
    local declared=3 examined=0 t marker
    for t in $fixtures; do
        examined=$((examined + 1))
        marker="observer fold repro: PASS"
        [ "$t" = tsan_observer_sandbox_probe ] && marker="observer sandbox probe: PASS"
        [ "$t" = observer_ns_deadlock ] && marker="observer namespace deadlock: PASS"
        tsan_warnings "$TESTS_DIR/$t.eigs"
        if [ "$LAST_RC" -eq 0 ] && [ "$WARNINGS" -eq 0 ] && grep -Fxq "$marker" <<< "$RUN_OUTPUT"; then
            echo "  PASS: $t TSan-clean"; PASS=$((PASS + 1))
        else
            echo "  FAIL: $t warnings=$WARNINGS rc=$LAST_RC"; FAIL=$((FAIL + 1))
            tsan_report <<< "$RUN_OUTPUT"
        fi
    done
    if [ "$examined" -eq "$declared" ]; then
        echo "  PASS: observer-fold fixtures examined == declared ($examined)"; PASS=$((PASS + 1))
    else
        echo "  FAIL: observer-fold fixtures examined == declared (examined=$examined declared=$declared)"; FAIL=$((FAIL + 1))
    fi
}

seeded_race_row() {
    echo "=== gate self-validation: a seeded race MUST be caught ==="
    local out rc w
    out=$(timeout "$TSAN_RUN_TIMEOUT" setarch -R env \
        EIGS_TSAN_SEEDED_RACE_CONTROL=1 "$EIGS" 2>&1)
    rc=$?
    w=$(printf '%s\n' "$out" | grep -c "WARNING: ThreadSanitizer" || true)
    if [ "$w" -gt 0 ]; then
        # One row, one verdict: --seeded-only and --row seeded require PASS == 1.
        # The failure print path, run on this real report, must show it whole
        # (the opening WARNING, both access stacks, the closing SUMMARY), or
        # the row fails even though the race was detected.
        local rep
        rep=$(tsan_report <<< "$out")
        if grep -q "WARNING: ThreadSanitizer" <<< "$rep" && grep -q "SUMMARY: ThreadSanitizer" <<< "$rep" \
           && [ "$(grep -c '#[0-9]' <<< "$rep")" -ge 2 ]; then
            echo "  PASS: seeded race detected ($w warnings) and its report prints whole ($(wc -l <<< "$rep") lines) — the gate is live"; PASS=$((PASS + 1))
        else
            echo "  FAIL: seeded race detected, but tsan_report did not print its whole report"; FAIL=$((FAIL + 1))
            printf '%s\n' "$out" | head -20
        fi
    else
        echo "  FAIL: seeded race NOT detected — the TSan gate is vacuous! (rc=$rc)"; FAIL=$((FAIL + 1))
    fi
}

misordered_publish_row() {
    echo "=== #2052 planted relaxed publish/consume race MUST be caught ==="
    local out rc w
    out=$(timeout "$TSAN_RUN_TIMEOUT" setarch -R env \
        EIGS_TSAN_MISORDERED_PUBLISH_CONTROL=1 "$EIGS" 2>&1)
    rc=$?
    w=$(printf '%s\n' "$out" | grep -c "WARNING: ThreadSanitizer" || true)
    if [ "$rc" -eq 124 ]; then
        echo "  FAIL: misordered publish/consume control HUNG"; FAIL=$((FAIL + 1))
    elif [ "$w" -gt 0 ]; then
        echo "  PASS: misordered relaxed publish/consume detected ($w warnings)"; PASS=$((PASS + 1))
    else
        echo "  FAIL: misordered relaxed publish/consume NOT detected (rc=$rc)"; FAIL=$((FAIL + 1))
    fi
}

compiler_env_count_hold_row() {
    echo "=== #2090 planted compiler env-count hold omission MUST be caught ==="
    local out rc w witness witness_rc witness_w
    # Verdict: the C control guarantees a real env append and count read are
    # unordered. Relaxed atomics rendezvous the workers without hiding the
    # planted access from TSan behind a synchronization edge.
    out=$(timeout "$TSAN_RUN_TIMEOUT" setarch -R env \
        EIGS_TSAN_COMPILER_ENV_COUNT_CONTROL=1 \
        EIGS_TSAN_COMPILER_ENV_COUNT_NO_HOLD=1 "$EIGS" 2>&1)
    rc=$?
    w=$(printf '%s\n' "$out" | grep -c "WARNING: ThreadSanitizer" || true)
    if [ "$rc" -eq 124 ]; then
        echo "  FAIL: compiler env-count hold omission control HUNG"; FAIL=$((FAIL + 1))
    elif [ "$w" -gt 0 ]; then
        echo "  PASS: deterministic compiler env-count hold omission detected ($w warnings)"; PASS=$((PASS + 1))
    else
        echo "  FAIL: compiler env-count hold omission NOT detected (rc=$rc)"; FAIL=$((FAIL + 1))
    fi

    # Second witness only: preserve the real-program reproduction, but never
    # let its scheduler-dependent result decide this row.
    witness=$(timeout "$TSAN_RUN_TIMEOUT" setarch -R env \
        EIGS_TSAN_COMPILER_ENV_COUNT_NO_HOLD=1 "$EIGS" \
        "$TESTS_DIR/loader_mt_define_result.eigs" 2>&1)
    witness_rc=$?
    witness_w=$(printf '%s\n' "$witness" | grep -c "WARNING: ThreadSanitizer" || true)
    echo "  INFO: real-program witness warnings=$witness_w rc=$witness_rc (non-verdict)"
}

rebind_call_row() {
    echo "=== #1171 call vs rebind of a shared binding must be race-free ==="
    # Threads call module-level functions while other threads rebind them to
    # fresh heap-capturing closures and reload a module that defines one;
    # main also calls through inline caches it filled before spawning. On
    # 965dfbd0 (a reader took its reference AFTER leaving the hold the rebind
    # frees under, and a call dropped its callee before the frame held the
    # chunk) all 3 runs crashed under TSan, with 76-286 reports.
    local fixture="$TESTS_DIR/rebind_call_race.eigs"
    if [ ! -f "$fixture" ]; then
        echo "  FAIL: rebind_call_race fixture missing ($fixture)"; FAIL=$((FAIL + 1)); return
    fi
    tsan_warnings "$fixture"
    if [ "$LAST_RC" -eq 124 ]; then
        echo "  FAIL: rebind_call_race HUNG (killed after ${TSAN_RUN_TIMEOUT}s)"; FAIL=$((FAIL + 1))
    elif [ "$WARNINGS" -ne 0 ]; then
        echo "  FAIL: rebind_call_race reported $WARNINGS ThreadSanitizer warning(s)"; FAIL=$((FAIL + 1))
        tsan_report <<< "$RUN_OUTPUT"
    elif [ "$LAST_RC" -ne 0 ] || ! grep -Fxq 'rebind call race: PASS' <<< "$RUN_OUTPUT"; then
        echo "  FAIL: rebind_call_race exited $LAST_RC without its PASS line"; FAIL=$((FAIL + 1))
        tail -5 <<< "$RUN_OUTPUT"
    else
        echo "  PASS: rebind_call_race TSan-clean, totals conserved"; PASS=$((PASS + 1))
    fi
}

captured_rebind_row() {
    echo "=== #1866 call vs rebind of a captured binding must be race-free ==="
    local fixture="$TESTS_DIR/tsan_captured_rebind.eigs"
    tsan_warnings "$fixture"
    if [ "$LAST_RC" -eq 0 ] && [ "$WARNINGS" -eq 0 ] && \
       grep -Fxq 'W5 total=40000 rebinds=20000' <<< "$RUN_OUTPUT"; then
        echo "  PASS: captured binding call/rebind TSan-clean"; PASS=$((PASS + 1))
    else
        echo "  FAIL: captured binding call/rebind warnings=$WARNINGS rc=$LAST_RC"; FAIL=$((FAIL + 1))
        grep -A2 'WARNING: ThreadSanitizer' <<< "$RUN_OUTPUT" | head -6
    fi
}

scope_boundary_row() {
    echo "=== #1144 scope boundary: the user-level race names NO loader structure ==="
    # tests/loader_mt_userrace.eigs races ON PURPOSE while workers load
    # modules. Asserting "zero reports" there would be a gate that can never
    # be green; asserting nothing would leave "out of scope" as a sentence. So
    # the row asserts what IS in scope: no LOADER STRUCTURE appears in any
    # report (no in-flight load stack, no module cache, no module-namespace
    # table). If #1144 regresses, one of those symbols comes back and this
    # goes red.
    #
    # #1489: the exit status is NOT a verdict. A program that races by design
    # may legally crash or hang, and requiring rc 0 from it turned the Phase 2
    # lane red (run 39325694662, rc 124 after a TSan SEGV). The row judges the
    # boundary on whatever reports the run produced, and REFUSES a capture
    # with none (§121: a check that examined nothing is vacuous). The race is
    # deterministic now: a ready/release barrier rendezvous workers before
    # their one-shot accesses to a separate race word, so one run suffices and
    # no retry can hide a control that stopped racing.
    local fixture="$TESTS_DIR/loader_mt_userrace.eigs"
    local forbidden='loading_stack|eigs_loading_|module_cache|module_lock|g_module_ns|module_ns_'
    local loader
    if [ ! -f "$fixture" ]; then
        echo "  FAIL: scope-boundary fixture missing ($fixture)"; FAIL=$((FAIL + 1)); return
    fi
    tsan_warnings "$fixture"
    loader=$(grep -cE "$forbidden" <<< "$RUN_OUTPUT" || true)
    if [ "$WARNINGS" -eq 0 ]; then
        echo "  FAIL (vacuous): the probe captured NO ThreadSanitizer report (rc=$LAST_RC): its"
        echo "        deliberate race did not run, so the boundary check examined nothing"
        FAIL=$((FAIL + 1))
    elif [ "$loader" -ne 0 ]; then
        echo "  FAIL (boundary): a LOADER STRUCTURE appears in the user-race reports ($loader line(s)) — #1144 regressed"
        grep -E "$forbidden" <<< "$RUN_OUTPUT" | head -6
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $WARNINGS report(s) examined, 0 loader frames (probe rc=$LAST_RC: racy by design, not a verdict)"
        PASS=$((PASS + 1))
    fi
}

loop_iterations_row() {
    echo "=== #1870 concurrent module-level loop publication must be race-free ==="
    local fixture="$TESTS_DIR/loader_mt_loop_iterations.eigs"
    local marker='loop iterations overlap: main=20000 worker=20000 entered=1'
    tsan_warnings "$fixture"
    if [ "$LAST_RC" -eq 124 ]; then
        echo "  FAIL: loader_mt_loop_iterations HUNG (killed after ${TSAN_RUN_TIMEOUT}s)"; FAIL=$((FAIL + 1))
    elif [ "$WARNINGS" -ne 0 ]; then
        echo "  FAIL: loader_mt_loop_iterations reported $WARNINGS ThreadSanitizer warning(s)"; FAIL=$((FAIL + 1))
        tsan_report <<< "$RUN_OUTPUT"
    elif [ "$LAST_RC" -ne 0 ] || ! grep -Fxq "$marker" <<< "$RUN_OUTPUT"; then
        echo "  FAIL: loader_mt_loop_iterations rc=$LAST_RC without concurrent-loop count evidence"; FAIL=$((FAIL + 1))
        tail -5 <<< "$RUN_OUTPUT"
    else
        echo "  PASS: loader_mt_loop_iterations TSan-clean; both overlapping loops completed 20000 iterations"; PASS=$((PASS + 1))
    fi
}

dict_readers_row() {
    echo "=== #1697 shared dict readers must not mutate order storage ==="
    local fixture="$TESTS_DIR/tsan_dict_readers.eigs"
    tsan_warnings "$fixture"
    if [ "$LAST_RC" -eq 0 ] && [ "$WARNINGS" -eq 0 ] && \
       grep -q 'dict readers: PASS' <<< "$RUN_OUTPUT"; then
        echo "  PASS: shared dict traversal is TSan-clean"; PASS=$((PASS + 1))
    else
        echo "  FAIL: shared dict readers warnings=$WARNINGS rc=$LAST_RC"; FAIL=$((FAIL + 1))
    fi
}

# --seeded-only (#1139): just the self-validation row, for a lane whose binary
# is not the stock tsan build (tsan-http). The rest of this script links
# build/tsan/*.o and is the stock lane's.
if [ "${1:-}" = "--seeded-only" ]; then
    seeded_race_row
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ] && [ "$PASS" -eq 1 ]; exit
fi
# --row NAME (#1489): one row through the same function the full run calls,
# so a row can be proven under load (taskset -c 0 nice -n 19) or against a
# planted binary without running the whole lane.
if [ "${1:-}" = "--row" ]; then
    ROW_EXPECTED=1
    case "${2:-}" in
        seeded)         seeded_race_row ;;
        rebind-call)    rebind_call_row ;;
        captured-rebind) captured_rebind_row ;;
        scope-boundary) scope_boundary_row ;;
        loop-iterations) loop_iterations_row ;;
        dict-readers)   dict_readers_row ;;
        misordered-publish) misordered_publish_row ;;
        compiler-env-count) compiler_env_count_hold_row ;;
        observer-fold) ROW_EXPECTED=4; observer_shared_fold_rows ;;
        *) echo "usage: test_tsan.sh --row seeded|rebind-call|captured-rebind|scope-boundary|loop-iterations|dict-readers|misordered-publish|compiler-env-count|observer-fold"; exit 2 ;;
    esac
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ] && [ "$PASS" -eq "$ROW_EXPECTED" ]; exit
fi

echo "=== concurrency slice must be race-free ==="
SLICE="test_concurrent test_spawn_parallel test_chan_dict_xthread test_spawn_gc \
       test_channel_nb test_spawn_channel_exit test_spawn_args \
       test_spawn_jit test_spawn_jit_warm test_obs_mt_race \
       tsan_no_yield_race tsan_sandbox_snapshot_race tsan_mt_clear_respawn \
       tsan_transfer_buffer_race tsan_message_buffer_copy tsan_dict_readers"
for t in $SLICE; do
    f="$TESTS_DIR/$t.eigs"
    [ -f "$f" ] || continue
    tsan_warnings "$f"
    w=$WARNINGS
    if [ "$LAST_RC" -eq 124 ]; then
        # A race-free program that stops making progress is a liveness bug —
        # fail in minutes, loudly, instead of hanging to the job timeout.
        echo "  FAIL: $t HUNG (killed after ${TSAN_RUN_TIMEOUT}s) — liveness bug"
        FAIL=$((FAIL + 1))
    elif [ "$w" -eq 0 ]; then
        echo "  PASS: $t race-free"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $t reported $w ThreadSanitizer warning(s)"
        tsan_report <<< "$RUN_OUTPUT"
        FAIL=$((FAIL + 1))
    fi
done

echo "=== thread worker error handoff must be race-free (#1745) ==="
for row in "thread_exit_join_catch.eigs:0:JOIN_CAUGHT" \
           "thread_exit_join_throw_value.eigs:0:JOIN_VALUE_CAUGHT" \
           "thread_exit_join_uncaught.eigs:1:missing_thread_join_uncaught" \
           "thread_exit_unjoined_death.eigs:1:MARK_END"; do
    f=${row%%:*}; rest=${row#*:}; want=${rest%%:*}; marker=${rest#*:}
    tsan_warnings "$TESTS_DIR/$f"
    if [ "$WARNINGS" -eq 0 ] && [ "$LAST_RC" -eq "$want" ] && \
       printf '%s\n' "$RUN_OUTPUT" | grep -q "$marker"; then
        echo "  PASS: $f error handoff TSan-clean (rc=$LAST_RC)"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $f warnings=$WARNINGS rc=$LAST_RC (want $want)"; FAIL=$((FAIL + 1))
    fi
done

echo "=== concurrent random streams have no races or duplicate draws (#1150) ==="
RANDOM_MT="$TESTS_DIR/random_mt_no_duplicates.eigs"
for run in 1 2 3; do
    out=$(timeout "$TSAN_RUN_TIMEOUT" setarch -R "$EIGS" "$RANDOM_MT" 2>&1)
    LAST_RC=$?
    w=$(printf '%s\n' "$out" | grep -c "WARNING: ThreadSanitizer" || true)
    case "$out" in *"All tests passed."*) summary_ok=1 ;; *) summary_ok=0 ;; esac
    if [ "$LAST_RC" -eq 0 ] && [ "$w" -eq 0 ] && [ "$summary_ok" -eq 1 ]; then
        echo "  PASS: random workers run $run: 0 duplicates, TSan-clean"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: random workers run $run: rc=$LAST_RC warnings=$w output='$out'"
        FAIL=$((FAIL + 1))
    fi
done

echo "=== declared concurrency shapes must be race-free (#1152) ==="
# This is an exact inventory, not a glob. These shapes were absent from the
# original 13-file slice; a rename must make the row red rather than silently
# shrinking its coverage.
SHAPE_FIXTURES="tsan_fanin3 tsan_close_blocked tsan_nested_spawn \
tsan_worker_throw tsan_worker_exit tsan_worker_tasks tsan_worker_eval \
tsan_spawn_emitted_jit"
SHAPE_DECLARED=8
SHAPE_EXAMINED=0
for t in $SHAPE_FIXTURES; do
    SHAPE_EXAMINED=$((SHAPE_EXAMINED + 1))
    f="$TESTS_DIR/$t.eigs"
    if [ ! -f "$f" ]; then
        echo "  FAIL: $t fixture missing ($f)"; FAIL=$((FAIL + 1)); continue
    fi
    expected_rc=0
    if [ "$t" = tsan_worker_exit ]; then expected_rc=5; fi
    tsan_warnings "$f"
    if [ "$LAST_RC" -eq 124 ]; then
        echo "  FAIL: $t HUNG (killed after ${TSAN_RUN_TIMEOUT}s)"; FAIL=$((FAIL + 1))
    elif [ "$WARNINGS" -ne 0 ]; then
        echo "  FAIL: $t reported $WARNINGS ThreadSanitizer warning(s)"; FAIL=$((FAIL + 1))
    elif [ "$LAST_RC" -ne "$expected_rc" ]; then
        echo "  FAIL: $t exited $LAST_RC (want $expected_rc)"; FAIL=$((FAIL + 1))
    elif [ "$t" = tsan_worker_exit ] && [ "$RUN_OUTPUT" != WORKER_EXIT_REQUEST ]; then
        echo "  FAIL: $t requires only the pre-exit marker; output='$RUN_OUTPUT'"; FAIL=$((FAIL + 1))
    elif [ "$t" = tsan_spawn_emitted_jit ] && [ "$JIT_BACKEND" != none ] &&
         ! grep -Eq '\[jit\].*compiled=[1-9][0-9]*' <<< "$RUN_OUTPUT"; then
        echo "  FAIL: $t did not compile emitted JIT code"; FAIL=$((FAIL + 1))
    elif [ "$t" = tsan_spawn_emitted_jit ] && [ "$JIT_BACKEND" != none ] &&
         ! grep -Eq '^hot[[:space:]]+80[[:space:]]+yes[[:space:]]+[0-9.]+%[[:space:]]+RET[[:space:]]' <<< "$RUN_OUTPUT"; then
        # The named hot row's RET is the native-return sentinel, written by
        # execution; compilation initializes advance to a byte count. The 80
        # entries precede spawn; MT calls do not increment this counter.
        echo "  FAIL: $t missing hot native-return witness after 80 warm calls"; FAIL=$((FAIL + 1))
    else
        if [ "$t" = tsan_spawn_emitted_jit ] && [ "$JIT_BACKEND" = none ]; then
            echo "  SKIP: $t emitted-code checks: this build has no JIT backend (jit-backend=$JIT_BACKEND)"
        fi
        echo "  PASS: $t TSan-clean and exited $expected_rc"; PASS=$((PASS + 1))
    fi
done
if [ "$SHAPE_EXAMINED" -eq "$SHAPE_DECLARED" ]; then
    echo "  PASS: concurrency-shape fixtures examined == declared ($SHAPE_EXAMINED)"; PASS=$((PASS + 1))
else
    echo "  FAIL: concurrency-shape fixtures examined == declared (examined=$SHAPE_EXAMINED declared=$SHAPE_DECLARED)"
    FAIL=$((FAIL + 1))
fi

echo "=== C embed observer contract (raw state and worker arming) ==="
if TSAN_OPTIONS="halt_on_error=1 exitcode=66" setarch -R \
        bash "$TESTS_DIR/test_embed_observer.sh"; then
    echo "  PASS: C embed observer contract"; PASS=$((PASS + 1))
else
    echo "  FAIL: C embed observer contract"; FAIL=$((FAIL + 1))
fi

echo "=== worker-tape under EIGS_TRACE must be race-free (#1142) ==="
TAPE_MT="$TESTS_DIR/trace_mt_workers.eigs"
TAPE_OUT="$TESTS_DIR/../build/tsan_trace_mt.tape"
if [ -f "$TAPE_MT" ]; then
    TSAN_OPTIONS="halt_on_error=1 exitcode=66" \
        timeout "$TSAN_RUN_TIMEOUT" setarch -R env EIGS_TRACE="$TAPE_OUT" "$EIGS" "$TAPE_MT" \
        >"$TESTS_DIR/../build/tsan_trace_mt.out" 2>"$TESTS_DIR/../build/tsan_trace_mt.err"
    LAST_RC=$?
    if [ "$LAST_RC" -eq 66 ]; then
        echo "  FAIL: worker-tape ThreadSanitizer race (exit 66)"
        FAIL=$((FAIL + 1))
        tsan_report < "$TESTS_DIR/../build/tsan_trace_mt.err"
    elif [ "$LAST_RC" -eq 124 ]; then
        echo "  FAIL: worker-tape HUNG (killed after ${TSAN_RUN_TIMEOUT}s)"
        FAIL=$((FAIL + 1))
    elif [ "$LAST_RC" -eq 0 ]; then
        echo "  PASS: worker-tape race-free under EIGS_TRACE"; PASS=$((PASS + 1))
    else
        echo "  FAIL: worker-tape rc=$LAST_RC"
        FAIL=$((FAIL + 1))
    fi
    rm -f "$TAPE_OUT"
else
    echo "  FAIL: worker-tape fixture missing"
    FAIL=$((FAIL + 1))
fi

echo "=== replay-workers under EIGS_REPLAY: causal values, TSan-clean ==="
RP_EIGS="$TESTS_DIR/trace_mt_replay_workers.eigs"
RP_TAPE="$TESTS_DIR/../build/tsan_replay_mt.tape"
RP_HDR="$TESTS_DIR/../build/tsan_replay_hdr.tape"
if [ -f "$RP_EIGS" ]; then
    printf 'print of 1\n' > "$TESTS_DIR/../build/tsan_one.eigs"
    header_rc=0
    EIGS_TRACE="$RP_HDR" timeout "$TSAN_RUN_TIMEOUT" setarch -R "$EIGS" \
        "$TESTS_DIR/../build/tsan_one.eigs" >/dev/null 2>&1 || header_rc=$?
    vline=$(head -1 "$RP_HDR" 2>/dev/null || true)
    trace_format=$(awk '/^#define TRACE_FORMAT_VERSION / { print $3; exit }' \
        "$TESTS_DIR/../src/trace.h")
    if [ "$header_rc" -ne 0 ] || [ "${vline%% *}" != V ] || \
       [ "$(printf '%s\n' "$vline" | awk '{print $2}')" != "$trace_format" ]; then
        echo "  FAIL: replay-workers header setup rc=$header_rc"
        FAIL=$((FAIL + 1))
    else
        {
            printf '%s\n' "$vline" 'B 0 1 1 0 root -' \
                'B 1 2 1 0 child 0 1' 'B 2 3 1 0 child 0 2'
            # The existing fixture performs 3000 takes in each of two workers.
            i=0
            while [ "$i" -lt 6000 ]; do
                printf 'N %d random=0.5\n' $((i % 2 + 1)); i=$((i+1))
            done
        } > "$RP_TAPE"
        TSAN_OPTIONS="halt_on_error=1 exitcode=66" \
            timeout "$TSAN_RUN_TIMEOUT" setarch -R env EIGS_REPLAY="$RP_TAPE" "$EIGS" "$RP_EIGS" \
            >"$TESTS_DIR/../build/tsan_replay_mt.out" 2>"$TESTS_DIR/../build/tsan_replay_mt.err"
        LAST_RC=$?
        if [ "$LAST_RC" -eq 66 ]; then
            echo "  FAIL: replay-workers ThreadSanitizer race (exit 66)"
            FAIL=$((FAIL + 1))
        elif [ "$LAST_RC" -eq 124 ]; then
            echo "  FAIL: replay-workers HUNG"
            FAIL=$((FAIL + 1))
        elif [ "$LAST_RC" -eq 0 ] && grep -qx 'a=1500 b=1500' \
                "$TESTS_DIR/../build/tsan_replay_mt.out"; then
            echo "  PASS: replay-workers causal values, TSan-clean"; PASS=$((PASS + 1))
        else
            echo "  FAIL: replay-workers rc=$LAST_RC (want 0 and exact two-worker values)"
            FAIL=$((FAIL + 1))
            head -3 "$TESTS_DIR/../build/tsan_replay_mt.err"
        fi
    fi
    rm -f "$RP_TAPE" "$RP_HDR" "$TESTS_DIR/../build/tsan_one.eigs"
else
    echo "  FAIL: replay-workers fixture missing"
    FAIL=$((FAIL + 1))
fi

echo "=== embed-concurrent under TSan: ANY report fails (#1334) ==="
ROOT="$TESTS_DIR/.."
TSAN_OBJS=$(ls "$ROOT"/build/tsan/*.o 2>/dev/null | grep -v '/main.o$' || true)
EC_BIN="$ROOT/build/tsan/embed_concurrent"
if [ -n "$TSAN_OBJS" ]; then
    gcc $WERROR_FLAGS -fsanitize=thread -g -O1 -o "$EC_BIN" \
        "$ROOT/src/embed_concurrent.c" $TSAN_OBJS -lm -lpthread \
        -I"$ROOT/src" -I"$ROOT/build"
    # Until #1334 this row counted only reports whose stack was in
    # src/trace.c, so a race anywhere else in the runtime passed. Now every
    # report fails it. The harness control uses atomic accesses, so this run
    # needs no suppressions: every TSan report is a failure.
    TSAN_OPTIONS="halt_on_error=0 exitcode=66" \
        timeout "$TSAN_RUN_TIMEOUT" setarch -R "$EC_BIN" \
        >"$ROOT/build/tsan_embed_concurrent.out" 2>"$ROOT/build/tsan_embed_concurrent.err"
    LAST_RC=$?
    EC_W=$(grep -c 'WARNING: ThreadSanitizer' "$ROOT/build/tsan_embed_concurrent.err" 2>/dev/null || true)
    if [ "$LAST_RC" -eq 124 ]; then
        echo "  FAIL: embed-concurrent HUNG (killed after ${TSAN_RUN_TIMEOUT}s)"; FAIL=$((FAIL + 1))
    elif [ "$LAST_RC" -eq 0 ] && [ "${EC_W:-0}" -eq 0 ] \
         && grep -q 'EMBED_CONCURRENT_OK' "$ROOT/build/tsan_embed_concurrent.out"; then
        echo "  PASS: embed-concurrent TSan-clean (0 reports; no suppressions)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: embed-concurrent rc=$LAST_RC reports=${EC_W:-0} (want rc 0, 0 reports)"
        FAIL=$((FAIL + 1))
        grep -A3 'WARNING: ThreadSanitizer' "$ROOT/build/tsan_embed_concurrent.err" | head -16
        grep -v '^[[:space:]]*PASS:' "$ROOT/build/tsan_embed_concurrent.out" | tail -5
    fi

    # FIRST USE, concurrently (#1334). The full run above warms every
    # lazily-built table on its first case, so a first-use race in the lexer,
    # compiler or VM (PR #1332 shipped one) can never show there. This mode
    # opens states and runs the first lex/compile/eval on workers released by
    # a barrier, with nothing evaluated on the main thread first. A process
    # gets exactly one first use, so it runs FU_RUNS separate processes, and
    # the first report halts each one. No suppressions: nothing planted runs.
    # Five, not one: a table filled after a lock that orders the workers (e.g.
    # builtins registration after the attach lock) is caught per process only
    # when two workers reach it before either finishes, measured at 4 of 5.
    # Calibrated once (PR for #1334): a lexer table filled on first call made
    # 5 of 5 runs exit 66 while the full run above still passed.
    FU_RUNS=${TSAN_FIRST_USE_RUNS:-5}
    FU_CLEAN=0; FU_FIRST_BAD=""
    rm -f "$ROOT/build/tsan_first_use.bad.err" "$ROOT/build/tsan_first_use.bad.out"
    fu=0
    while [ "$fu" -lt "$FU_RUNS" ]; do
        fu=$((fu + 1))
        EMBED_CONCURRENT_ONLY=first-use TSAN_OPTIONS="halt_on_error=1 exitcode=66" \
            timeout "$TSAN_RUN_TIMEOUT" setarch -R "$EC_BIN" \
            >"$ROOT/build/tsan_first_use.out" 2>"$ROOT/build/tsan_first_use.err"
        LAST_RC=$?
        if [ "$LAST_RC" -eq 0 ] && grep -q 'EMBED_CONCURRENT_OK' "$ROOT/build/tsan_first_use.out" \
           && ! grep -q 'WARNING: ThreadSanitizer' "$ROOT/build/tsan_first_use.err"; then
            FU_CLEAN=$((FU_CLEAN + 1))
        elif [ -z "$FU_FIRST_BAD" ]; then
            FU_FIRST_BAD="run $fu rc=$LAST_RC"
            [ "$LAST_RC" -eq 124 ] && FU_FIRST_BAD="$FU_FIRST_BAD (HUNG)"
            cp "$ROOT/build/tsan_first_use.err" "$ROOT/build/tsan_first_use.bad.err"
            cp "$ROOT/build/tsan_first_use.out" "$ROOT/build/tsan_first_use.bad.out"
        fi
    done
    if [ "$FU_RUNS" -gt 0 ] && [ "$FU_CLEAN" -eq "$FU_RUNS" ]; then
        echo "  PASS: concurrent first use TSan-clean ($FU_CLEAN/$FU_RUNS fresh processes, no warm-up)"; PASS=$((PASS + 1))
    else
        echo "  FAIL: concurrent first use: $FU_CLEAN/$FU_RUNS runs clean; first bad: ${FU_FIRST_BAD:-none (FU_RUNS=$FU_RUNS)}"
        FAIL=$((FAIL + 1))
        grep -A3 'WARNING: ThreadSanitizer' "$ROOT/build/tsan_first_use.bad.err" 2>/dev/null | head -16
        grep 'FAIL' "$ROOT/build/tsan_first_use.bad.out" 2>/dev/null | head -5
    fi
else
    # EC_SUPP named a suppressions file that #1599 removed; under set -u the
    # stale reference crashed this branch before it could report (2026-10-28).
    echo "  FAIL: no TSan objects in build/tsan (run make tsan first)"
    FAIL=$((FAIL + 1))
fi

echo "=== dict keys written by a worker must outlive it, TSan-clean (#1141) ==="
# The release oracle (tests/test_dict_keys_mt.sh) reads the OUTPUT; this arm
# reads the sanitizer. They see the same defect from opposite sides: without
# the fix the release binary prints freed bytes with rc 0 on two of these
# shapes (silent), while TSan names it — heap-use-after-free in make_str <-
# builtin_keys against a free in env_intern_table_unref <- eigs_thread_detach.
# The fixture list is DECLARED, not globbed, and a missing member is a FAIL:
# the `[ -f ] || continue` in the slice above is a silent shrink if a fixture
# is ever renamed (mechanical-gates §121).
#
# Measured discrimination against a pristine pre-fix build, because a row that
# cannot go red on the known-bad tree is decoration (mechanical-gates §64):
#   inplace / list / nested / concurrent  TSan heap-use-after-free (1, 1, 4, 1)
#   reuse                                 0 warnings, exits 1 — the `rc` arm
#   module                                0 warnings, exits 0 — this row does
#     NOT discriminate here. TSan does not see the module-namespace half (the
#     env binding name): the read is on the main thread after the worker is
#     joined, so there is no cross-thread access to report. Its harm witness
#     is the ASAN lane, where the report lands in the probe's own capture and
#     tests/test_dict_keys_mt.sh's `dict_keys_mt_module` row goes red —
#     verified by building the `env-name-not-rehomed` mutant with `make asan`
#     and running that oracle (3 rows red, including this probe).
DKM_FIXTURES="dict_keys_mt_inplace dict_keys_mt_list dict_keys_mt_nested \
dict_keys_mt_reuse dict_keys_mt_concurrent dict_keys_mt_module"
DKM_DECLARED=6
DKM_EXAMINED=0
for t in $DKM_FIXTURES; do
    DKM_EXAMINED=$((DKM_EXAMINED + 1))
    f="$TESTS_DIR/$t.eigs"
    if [ ! -f "$f" ]; then
        echo "  FAIL: $t fixture missing ($f)"; FAIL=$((FAIL + 1)); continue
    fi
    tsan_warnings "$f"
    w=$WARNINGS
    if [ "$LAST_RC" -eq 124 ]; then
        echo "  FAIL: $t HUNG (killed after ${TSAN_RUN_TIMEOUT}s)"; FAIL=$((FAIL + 1))
    elif [ "$w" -ne 0 ]; then
        echo "  FAIL: $t reported $w ThreadSanitizer warning(s)"
        FAIL=$((FAIL + 1))
        tsan_report <<< "$RUN_OUTPUT"
    elif [ "$LAST_RC" -ne 0 ]; then
        # A probe that DIED has not shown that the keys survive; a quiet
        # sanitizer on a truncated run is absence of evidence.
        echo "  FAIL: $t exited $LAST_RC (want 0)"; FAIL=$((FAIL + 1))
    else
        echo "  PASS: $t TSan-clean and exited 0"; PASS=$((PASS + 1))
    fi
done
if [ "$DKM_EXAMINED" -eq "$DKM_DECLARED" ] && [ "$DKM_EXAMINED" -gt 0 ]; then
    echo "  PASS: dict-key fixtures examined == declared ($DKM_EXAMINED)"; PASS=$((PASS + 1))
else
    echo "  FAIL: dict-key fixtures examined == declared (examined=$DKM_EXAMINED declared=$DKM_DECLARED)"
    FAIL=$((FAIL + 1))
fi

echo "=== loader from workers must be race-free (#1144) ==="
# The loader's OWN structures: the per-thread in-flight stack, the module
# cache, the process-global module-namespace table and the module env's
# count. DECLARED, not globbed — a missing fixture is a FAIL, never a silent
# shrink (§121). Measured discriminating against a6333bb: s_import_concurrent
# 8/12/5 warnings, p3_import_race 3/5/5 (free in module_ns_rebuild vs read in
# module_ns_slot <- eigs_module_ns_env <- dict_get_hashed).
#
# tests/loader_mt_loadfile.eigs (two workers load the SAME module, so both
# REBIND the same global names) stays out of this list. #1171 made that rebind
# race-free (the value and the assign-count are written inside the hold:
# 965dfbd0 reported 3 per run, the #1171 tree 0 in 15 runs). But its workers
# also CREATE global bindings on their first load, and an inline-cache check
# on another thread reads the global env's binding_version without the lock:
# a formal race on that one word (seen in 1 of 30 runs of
# loader_mt_userrace.eigs on the Phase 2 branch), which would make a
# zero-report row flaky. It is a release-binary correctness row in
# tests/test_loader_mt.sh instead.
LDR_FIXTURES="loader_mt_import loader_mt_cycle loader_mt_define_result"
LDR_DECLARED=3
LDR_EXAMINED=0
for t in $LDR_FIXTURES; do
    LDR_EXAMINED=$((LDR_EXAMINED + 1))
    f="$TESTS_DIR/$t.eigs"
    if [ ! -f "$f" ]; then
        echo "  FAIL: $t fixture missing ($f)"; FAIL=$((FAIL + 1)); continue
    fi
    tsan_warnings "$f"
    w=$WARNINGS
    if [ "$LAST_RC" -eq 124 ]; then
        echo "  FAIL: $t HUNG (killed after ${TSAN_RUN_TIMEOUT}s)"; FAIL=$((FAIL + 1))
    elif [ "$w" -ne 0 ]; then
        echo "  FAIL: $t reported $w ThreadSanitizer warning(s)"; FAIL=$((FAIL + 1))
        tsan_report <<< "$RUN_OUTPUT"
    elif [ "$LAST_RC" -ne 0 ]; then
        echo "  FAIL: $t exited $LAST_RC (want 0) — a quiet sanitizer on a truncated run is absence of evidence"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $t TSan-clean and exited 0"; PASS=$((PASS + 1))
    fi
done
# Two fixtures live in their own directory (their `import` resolution is
# relative to the probe file): the module-namespace read path, and the
# same-path concurrent import that must yield exactly ONE module instance.
LDR_DIR_FIXTURES="lm_nsread lm_same_import"
LDR_DIR_DECLARED=2
for t in $LDR_DIR_FIXTURES; do
    LDR_EXAMINED=$((LDR_EXAMINED + 1))
    f="$TESTS_DIR/loader_mt_modules/$t.eigs"
    if [ ! -f "$f" ]; then
        echo "  FAIL: $t fixture missing ($f)"; FAIL=$((FAIL + 1)); continue
    fi
    tsan_warnings "$f"
    if [ "$WARNINGS" -eq 0 ] && [ "$LAST_RC" -eq 0 ]; then
        echo "  PASS: $t TSan-clean and exited 0"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $t reported $WARNINGS warning(s), rc=$LAST_RC"; FAIL=$((FAIL + 1))
        tsan_report <<< "$RUN_OUTPUT"
    fi
done
LDR_TOTAL=$((LDR_DECLARED + LDR_DIR_DECLARED))
if [ "$LDR_EXAMINED" -eq "$LDR_TOTAL" ] && [ "$LDR_EXAMINED" -gt 0 ]; then
    echo "  PASS: loader fixtures examined == declared ($LDR_EXAMINED)"; PASS=$((PASS + 1))
else
    echo "  FAIL: loader fixtures examined == declared (examined=$LDR_EXAMINED declared=$LDR_TOTAL)"
    FAIL=$((FAIL + 1))
fi

rebind_call_row

observer_shared_fold_rows

scope_boundary_row

loop_iterations_row

echo "=== observer arming sets must be race-free (#1145) ==="
# (a) the spawn shape, occurrence tier + the #827 history control.
ARM_FIXTURES="arming_mt_occ arming_mt_hist"
ARM_DECLARED=2
ARM_EXAMINED=0
for t in $ARM_FIXTURES; do
    ARM_EXAMINED=$((ARM_EXAMINED + 1))
    f="$TESTS_DIR/$t.eigs"
    if [ ! -f "$f" ]; then
        echo "  FAIL: $t fixture missing ($f)"; FAIL=$((FAIL + 1)); continue
    fi
    tsan_warnings "$f"
    if [ "$LAST_RC" -eq 124 ]; then
        echo "  FAIL: $t HUNG (killed after ${TSAN_RUN_TIMEOUT}s)"; FAIL=$((FAIL + 1))
    elif [ "$WARNINGS" -ne 0 ]; then
        echo "  FAIL: $t reported $WARNINGS ThreadSanitizer warning(s)"; FAIL=$((FAIL + 1))
        tsan_report <<< "$RUN_OUTPUT"
    elif [ "$LAST_RC" -ne 0 ]; then
        echo "  FAIL: $t exited $LAST_RC (want 0)"; FAIL=$((FAIL + 1))
    else
        echo "  PASS: $t TSan-clean and exited 0"; PASS=$((PASS + 1))
    fi
done
if [ "$ARM_EXAMINED" -eq "$ARM_DECLARED" ] && [ "$ARM_EXAMINED" -gt 0 ]; then
    echo "  PASS: arming fixtures examined == declared ($ARM_EXAMINED)"; PASS=$((PASS + 1))
else
    echo "  FAIL: arming fixtures examined == declared (examined=$ARM_EXAMINED declared=$ARM_DECLARED)"
    FAIL=$((FAIL + 1))
fi

# (b) the TWO-STATE shape. No spawn, so every per-state flag is 0 and no
# .eigs program can express it — a C harness against the TSan objects, the
# same way embed-concurrent is built above. Pre-fix witness: 6/14/9 warnings
# across three runs, all on g_arm_names/g_arm_count (arm_set_has <-
# trace_arm_history_name <- compile_node_inner).
ATS_SRC="$TESTS_DIR/test_arming_two_states.c"
ATS_BIN="$ROOT/build/tsan/test_arming_two_states"
if [ -n "$TSAN_OBJS" ] && [ -f "$ATS_SRC" ]; then
    gcc $WERROR_FLAGS -fsanitize=thread -g -O1 -o "$ATS_BIN" \
        "$TESTS_DIR/test_arming_two_states.c" $TSAN_OBJS -lm -lpthread \
        -I"$ROOT/src" -I"$ROOT/build"
    TSAN_OPTIONS="halt_on_error=0 exitcode=0" \
        timeout "$TSAN_RUN_TIMEOUT" setarch -R "$ATS_BIN" \
        >"$ROOT/build/tsan_arming_two_states.out" 2>"$ROOT/build/tsan_arming_two_states.err"
    LAST_RC=$?
    ATS_W=$(grep -c 'WARNING: ThreadSanitizer' "$ROOT/build/tsan_arming_two_states.err" 2>/dev/null || true)
    if [ "$LAST_RC" -eq 0 ] && [ "${ATS_W:-0}" -eq 0 ] \
       && grep -q 'ARMING_TWO_STATES: 7 passed, 0 failed' "$ROOT/build/tsan_arming_two_states.out"; then
        echo "  PASS: two-state arming TSan-clean (no spawn, 0 warnings)"; PASS=$((PASS + 1))
    else
        echo "  FAIL: two-state arming rc=$LAST_RC warnings=${ATS_W:-0}"
        FAIL=$((FAIL + 1))
        grep -A3 'WARNING: ThreadSanitizer' "$ROOT/build/tsan_arming_two_states.err" | head -10
    fi
else
    echo "  FAIL: two-state arming harness or tsan objects missing"
    FAIL=$((FAIL + 1))
fi

echo "=== thread handles + module-env lock must be race-free (#1146, #1161) ==="
# Two claims on this lane:
#   (a) the module NAMESPACE under two workers. Pre-fix on f532c8d this fixture
#       reported 61 ThreadSanitizer findings (57 data races + 4
#       heap-use-after-free) and then died of SIGSEGV inside strcmp; on the
#       release binary it crashed 5/5. Counting STACK FRAMES across those
#       reports: 77 named env_set_local_hashed (the #607 lock that never
#       engaged, because env_mt_shared() asked `parent == NULL`) and 64 named
#       dict_set_hashed_raw (the namespace's dict MIRROR — the other half of
#       the same structure, which is why locking only the env was not enough).
#   (b) the thread-handle probes. handles_double_join is the one that matters:
#       pre-fix it made TWO pthread_join calls on one tid, which TSan itself
#       refuses with `CHECK failed: sanitizer_thread_registry.cpp:348`. A
#       hung/aborted run here is a FAIL, not a quiet pass. ROUND 2 adds
#       handles_channel_stale: a forged-generation `recv` must be refused, and
#       the critic's mutant that served it instead made a stripped-generation
#       `recv` HANG — a liveness failure this lane must see as a FAIL.
#       handles_store_stale is deliberately NOT on this lane: it is
#       single-threaded (255 store open/close cycles) and has nothing for
#       ThreadSanitizer to say; it runs on the release and ASan lanes.
HMT_FIXTURES="handles_double_join handles_join_twice handles_reuse handles_full \
handles_channel_stale"
HMT_DECLARED=5
HMT_EXAMINED=0
for t in $HMT_FIXTURES; do
    HMT_EXAMINED=$((HMT_EXAMINED + 1))
    f="$TESTS_DIR/$t.eigs"
    if [ ! -f "$f" ]; then
        echo "  FAIL: $t fixture missing ($f)"; FAIL=$((FAIL + 1)); continue
    fi
    tsan_warnings "$f"
    if [ "$LAST_RC" -eq 124 ]; then
        echo "  FAIL: $t HUNG (killed after ${TSAN_RUN_TIMEOUT}s) — a double pthread_join?"
        FAIL=$((FAIL + 1))
    elif [ "$WARNINGS" -ne 0 ]; then
        echo "  FAIL: $t reported $WARNINGS ThreadSanitizer warning(s)"; FAIL=$((FAIL + 1))
        tsan_report <<< "$RUN_OUTPUT"
    elif [ "$LAST_RC" -ne 0 ]; then
        echo "  FAIL: $t exited $LAST_RC (want 0) — a quiet sanitizer on a truncated run is absence of evidence"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $t TSan-clean and exited 0"; PASS=$((PASS + 1))
    fi
done
# The #1161 fixture lives in its own directory (its `import` resolves relative
# to the probe file).
HMT_EXAMINED=$((HMT_EXAMINED + 1))
MODENV_F="$TESTS_DIR/handles_mt_modules/hm_modenv.eigs"
if [ -f "$MODENV_F" ]; then
    tsan_warnings "$MODENV_F"
    if [ "$LAST_RC" -eq 124 ]; then
        echo "  FAIL: hm_modenv HUNG (killed after ${TSAN_RUN_TIMEOUT}s)"; FAIL=$((FAIL + 1))
    elif [ "$WARNINGS" -eq 0 ] && [ "$LAST_RC" -eq 0 ]; then
        echo "  PASS: hm_modenv TSan-clean and exited 0"; PASS=$((PASS + 1))
    else
        echo "  FAIL: hm_modenv reported $WARNINGS warning(s), rc=$LAST_RC"; FAIL=$((FAIL + 1))
        tsan_report <<< "$RUN_OUTPUT"
    fi
else
    echo "  FAIL: hm_modenv fixture missing ($MODENV_F)"; FAIL=$((FAIL + 1))
fi
HMT_TOTAL=$((HMT_DECLARED + 1))
if [ "$HMT_EXAMINED" -eq "$HMT_TOTAL" ] && [ "$HMT_EXAMINED" -gt 0 ]; then
    echo "  PASS: handle/modenv fixtures examined == declared ($HMT_EXAMINED)"; PASS=$((PASS + 1))
else
    echo "  FAIL: handle/modenv fixtures examined == declared (examined=$HMT_EXAMINED declared=$HMT_TOTAL)"
    FAIL=$((FAIL + 1))
fi

seeded_race_row
misordered_publish_row
compiler_env_count_hold_row
observer_shared_fold_rows
captured_rebind_row

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
