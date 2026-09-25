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
    gcc $WERROR_FLAGS -fsanitize=thread -g -O1 -o "$EC_BIN" \
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
        timeout "$TSAN_RUN_TIMEOUT" setarch -R "$EIGS" "$f" 2>&1 | grep -A2 "ThreadSanitizer" | head -6
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
# tests/loader_mt_loadfile.eigs is DELIBERATELY NOT in this list. It is a
# release-binary correctness row in tests/test_loader_mt.sh instead: two
# workers loading the SAME module both REBIND the same global name, which is
# the documented user-level shared-mutable-state race (docs/CONCURRENCY.md),
# and TSan reports it on the binding's VALUE, its refcount and its observer
# slot — the class #607 declares out of scope ("two threads racing on the
# SAME slot's value or assign-count"; tracked as #1171). A row that can never be clean is not a
# gate (§13/§23).
LDR_FIXTURES="loader_mt_import loader_mt_cycle"
LDR_DECLARED=2
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
        timeout "$TSAN_RUN_TIMEOUT" setarch -R "$EIGS" "$f" 2>&1 | grep -A2 "ThreadSanitizer" | head -6
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
        timeout "$TSAN_RUN_TIMEOUT" setarch -R "$EIGS" "$f" 2>&1 | grep -A2 "ThreadSanitizer" | head -6
    fi
done
LDR_TOTAL=$((LDR_DECLARED + LDR_DIR_DECLARED))
if [ "$LDR_EXAMINED" -eq "$LDR_TOTAL" ] && [ "$LDR_EXAMINED" -gt 0 ]; then
    echo "  PASS: loader fixtures examined == declared ($LDR_EXAMINED)"; PASS=$((PASS + 1))
else
    echo "  FAIL: loader fixtures examined == declared (examined=$LDR_EXAMINED declared=$LDR_TOTAL)"
    FAIL=$((FAIL + 1))
fi

echo "=== #1144 scope boundary: the user-level race names NO loader structure ==="
# tests/loader_mt_userrace.eigs is the one loader-shaped program that is NOT
# expected to be clean: two workers load a module whose `define` rebinds one
# global that the other is calling — the same-slot value/assign-count class
# `src/eigenscript.c`'s #607 comment declares out of scope, filed on its own.
#
# Asserting "zero reports" there would be a gate that can never be green.
# Asserting nothing would leave "out of scope" as a sentence. So the row
# asserts what IS in scope: that no LOADER STRUCTURE appears in any report —
# no in-flight load stack, no module cache, no module-namespace table. If
# #1144 regresses, one of those symbols comes back here and this goes red.
#
# A capture with zero reports cannot witness the boundary (§121: a check that
# examined nothing is vacuous), so the row retries for a racing capture and
# says so if it never gets one.
UR_FIXTURE="$TESTS_DIR/loader_mt_userrace.eigs"
UR_FORBIDDEN='loading_stack|eigs_loading_|module_cache|module_lock|g_module_ns|module_ns_'
if [ -f "$UR_FIXTURE" ]; then
    UR_OUT=""; UR_W=0; UR_RC=0; UR_TRIES=0
    while [ "$UR_TRIES" -lt 3 ]; do
        UR_TRIES=$((UR_TRIES + 1))
        UR_OUT=$(timeout "$TSAN_RUN_TIMEOUT" setarch -R "$EIGS" "$UR_FIXTURE" 2>&1)
        UR_RC=$?
        UR_W=$(printf '%s\n' "$UR_OUT" | grep -c "WARNING: ThreadSanitizer" || true)
        [ "$UR_W" -gt 0 ] && break
    done
    UR_LOADER=$(printf '%s\n' "$UR_OUT" | grep -cE "$UR_FORBIDDEN" || true)
    if [ "$UR_RC" -ne 0 ]; then
        echo "  FAIL: scope-boundary probe exited $UR_RC (want 0)"; FAIL=$((FAIL + 1))
    elif [ "$UR_W" -eq 0 ]; then
        echo "  FAIL: scope-boundary probe raced nothing in $UR_TRIES attempts — the"
        echo "        boundary check examined an empty capture, which proves nothing"
        FAIL=$((FAIL + 1))
    elif [ "$UR_LOADER" -ne 0 ]; then
        echo "  FAIL: a LOADER STRUCTURE appears in the user-race reports ($UR_LOADER line(s)) — #1144 regressed"
        printf '%s\n' "$UR_OUT" | grep -E "$UR_FORBIDDEN" | head -6
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: user-race reports name no loader structure ($UR_W report(s) examined, 0 loader frames)"
        PASS=$((PASS + 1))
    fi
else
    echo "  FAIL: scope-boundary fixture missing ($UR_FIXTURE)"; FAIL=$((FAIL + 1))
fi

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
        timeout "$TSAN_RUN_TIMEOUT" setarch -R "$EIGS" "$f" 2>&1 | grep -A2 "ThreadSanitizer" | head -6
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
        timeout "$TSAN_RUN_TIMEOUT" setarch -R "$EIGS" "$f" 2>&1 | grep -A2 "ThreadSanitizer" | head -6
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
        timeout "$TSAN_RUN_TIMEOUT" setarch -R "$EIGS" "$MODENV_F" 2>&1 | grep -A2 "ThreadSanitizer" | head -6
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
