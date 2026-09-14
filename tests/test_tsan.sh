#!/bin/bash
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

# Every run is timeout-bounded. The seeded race is DELIBERATE UB (a lost
# update on the slot double-decrefs the displaced element), and undefined
# behavior may legally hang — on 4-core CI runners it did, at ~1/3 rate,
# burning the 6h job timeout each time. TSan's warnings are emitted as they
# happen, so a killed run still yields its warning count.
TSAN_RUN_TIMEOUT=${TSAN_RUN_TIMEOUT:-120}
# Sets WARNINGS + LAST_RC as globals — deliberately NOT echo-and-capture:
# `w=$(fn)` would run fn in a subshell and the parent would never see
# LAST_RC, silently disabling the hang branch (caught by a planted hang).
WARNINGS=0
LAST_RC=0
tsan_warnings() {
    local out
    out=$(timeout "$TSAN_RUN_TIMEOUT" setarch -R "$EIGS" "$1" 2>&1)
    LAST_RC=$?
    WARNINGS=$(printf '%s\n' "$out" | grep -c "WARNING: ThreadSanitizer" || true)
}

echo "=== concurrency slice must be race-free ==="
SLICE="test_concurrent test_spawn_parallel test_chan_dict_xthread test_spawn_gc \
       test_channel_nb test_spawn_channel_exit test_spawn_args \
       test_spawn_arena_return test_spawn_jit test_spawn_jit_warm test_obs_mt_race \
       tsan_no_yield_race tsan_sandbox_snapshot_race"
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
        timeout "$TSAN_RUN_TIMEOUT" setarch -R "$EIGS" "$f" 2>&1 | grep -A2 "ThreadSanitizer" | head -6
        FAIL=$((FAIL + 1))
    fi
done

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
        grep -A2 "ThreadSanitizer" "$TESTS_DIR/../build/tsan_trace_mt.err" | head -8
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

echo "=== replay-workers under EIGS_REPLAY must fail-loud, TSan-clean (#1142) ==="
RP_EIGS="$TESTS_DIR/trace_mt_replay_workers.eigs"
RP_TAPE="$TESTS_DIR/../build/tsan_replay_mt.tape"
RP_HDR="$TESTS_DIR/../build/tsan_replay_hdr.tape"
if [ -f "$RP_EIGS" ]; then
    printf 'print of 1\n' > "$TESTS_DIR/../build/tsan_one.eigs"
    EIGS_TRACE="$RP_HDR" timeout "$TSAN_RUN_TIMEOUT" setarch -R "$EIGS" \
        "$TESTS_DIR/../build/tsan_one.eigs" >/dev/null 2>&1 || true
    {
        head -1 "$RP_HDR" 2>/dev/null || echo "V 3 0.43.0"
        i=0
        while [ "$i" -lt 4000 ]; do printf 'N random=0.5\n'; i=$((i+1)); done
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
    elif [ "$LAST_RC" -eq 1 ] && grep -q 'not replayable under EIGS_REPLAY' \
            "$TESTS_DIR/../build/tsan_replay_mt.err"; then
        echo "  PASS: replay-workers fail-loud, TSan-clean"; PASS=$((PASS + 1))
    else
        echo "  FAIL: replay-workers rc=$LAST_RC (want 1 + diagnostic)"
        FAIL=$((FAIL + 1))
        head -3 "$TESTS_DIR/../build/tsan_replay_mt.err"
    fi
    rm -f "$RP_TAPE" "$RP_HDR" "$TESTS_DIR/../build/tsan_one.eigs"
else
    echo "  FAIL: replay-workers fixture missing"
    FAIL=$((FAIL + 1))
fi

echo "=== embed-concurrent under TSan (shutdown-while-sibling) ==="
ROOT="$TESTS_DIR/.."
TSAN_OBJS=$(ls "$ROOT"/build/tsan/*.o 2>/dev/null | grep -v '/main.o$' || true)
EC_BIN="$ROOT/build/tsan/embed_concurrent"
if [ -n "$TSAN_OBJS" ]; then
    gcc -Werror=switch -Werror=comment -Werror=misleading-indentation -fsanitize=thread -g -O1 -o "$EC_BIN" \
        "$ROOT/src/embed_concurrent.c" $TSAN_OBJS -lm -lpthread \
        -I"$ROOT/src" -I"$ROOT/build"
    # halt_on_error=0: the original thresh_worker hits a pre-existing
    # compile_ast verify_self race (compiler.c). The claim here is that
    # the tape/shutdown paths in src/trace.c are quiet.
    TSAN_OPTIONS="halt_on_error=0 exitcode=0" \
        timeout "$TSAN_RUN_TIMEOUT" setarch -R "$EC_BIN" \
        >"$ROOT/build/tsan_embed_concurrent.out" 2>"$ROOT/build/tsan_embed_concurrent.err"
    LAST_RC=$?
    TRACE_RACE=$(grep -c 'src/trace.c' "$ROOT/build/tsan_embed_concurrent.err" 2>/dev/null || true)
    if grep -q 'EMBED_CONCURRENT_OK' "$ROOT/build/tsan_embed_concurrent.out" \
       && [ "${TRACE_RACE:-0}" -eq 0 ]; then
        echo "  PASS: embed-concurrent TSan-clean (shutdown-while-sibling, 0 trace.c reports)"; PASS=$((PASS + 1))
    else
        echo "  FAIL: embed-concurrent tsan rc=$LAST_RC trace.c-reports=$TRACE_RACE"
        FAIL=$((FAIL + 1))
        grep -A2 'src/trace.c' "$ROOT/build/tsan_embed_concurrent.err" | head -12
    fi
else
    echo "  FAIL: tsan objects missing"
    FAIL=$((FAIL + 1))
fi

echo "=== gate self-validation: a seeded race MUST be caught ==="
tsan_warnings "$TESTS_DIR/tsan_seeded_race.eigs"
w=$WARNINGS
if [ "$LAST_RC" -eq 124 ]; then
    echo "  note: seeded race killed after ${TSAN_RUN_TIMEOUT}s (UB may hang; detection is what's asserted)"
fi
if [ "$w" -gt 0 ]; then
    echo "  PASS: seeded race detected ($w warnings) — the gate is live"; PASS=$((PASS + 1))
else
    echo "  FAIL: seeded race NOT detected — the TSan gate is vacuous!"; FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
