#!/usr/bin/env bash
# STOP-R21-1 / RULING R21-1: the result bound moves with the R2.2 clamp removal.
set -u
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
EIGS=${EIGS:-$TESTS_DIR/../src/eigenscript}
. "$TESTS_DIR/lsan_classify.sh"
. "$TESTS_DIR/timeout_select.sh"
eigs_timeout_select 20
run_tier() (
    unset EIGS_JIT_OFF EIGS_JIT_OSR_THRESHOLD EIGS_JIT_OSR_OFF
    unset EIGS_JIT_ENTRY_THRESHOLD EIGS_JIT_ITER_THRESHOLD
    unset EIGS_JIT_STATS EIGS_JIT_STOPS EIGS_JIT_HOT
    unset EIGS_TRACE EIGS_REPLAY EIGS_OBS_FORCE EIGS_STRICT
    case "$1" in
        off) export EIGS_JIT_OFF=1 ;;
        osr) export EIGS_JIT_OSR_THRESHOLD=1 ;;
    esac
    $EIGS_TMO "$EIGS" "$TESTS_DIR/fixtures/phase2_r21_threshold.eigs" </dev/null
)
echo "PLAN: 3"
failed=0
for tier in off default osr; do
    output=$(run_tier "$tier" 2>&1); rc=$?
    sanitizer=$(lsan_classify_name "$output")
    if [ "$rc" -eq 0 ] && [ "$sanitizer" = none ] && [ "$output" = true ]; then
        echo "PASS: R2.2 threshold $tier prints true"
    else
        echo "FAIL: R2.2 threshold $tier (rc=$rc sanitizer=$sanitizer; expected exactly true)"
        printf '%s\n' "$output"
        failed=1
    fi
done
exit "$failed"
