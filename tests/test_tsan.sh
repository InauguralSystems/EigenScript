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
       test_spawn_arena_return test_spawn_jit"
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
