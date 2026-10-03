#!/usr/bin/env bash
# Ordinary embed contract, compiled with the CLI's owning flags and objects.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
variant=
for candidate in "$ROOT"/build/*/eigenscript; do
    if [[ "$ROOT/src/eigenscript" -ef "$candidate" ]]; then
        variant=$(basename "$(dirname "$candidate")")
        break
    fi
done
# build.sh CI has no owning object variant; explicitly compile release there.
if [[ -z "$variant" ]]; then
    variant=release
    echo "missing capability: build.sh layout; checking release objects"
fi
make --no-print-directory -C "$ROOT" -f tests/missing-capability.mk \
    "COLD_VARIANT=$variant" "build/$variant/test_missing_capability"
source "$ROOT/tests/lsan_classify.sh"
# Match the suite's portable timeout/gtimeout/direct fallback convention.
mc_tmo() {
    local seconds="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$seconds" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$seconds" "$@"
    else "$@"; fi
}
summary_pattern='^missing capability: omitted=([0-9]+) present=([0-9]+) checks=([0-9]+) failed=0$'
for strict in unset 0 1; do
    for jit in on off osr; do
        output=$(mktemp)
        rc=0
        (
            unset EIGS_STRICT EIGS_JIT_OFF EIGS_JIT_OSR_THRESHOLD EIGS_TRACE EIGS_REPLAY EIGS_OBS_FORCE
            unset EIGS_JIT_ENTRY_THRESHOLD EIGS_JIT_ITER_THRESHOLD EIGS_JIT_OSR_OFF
            if [[ "$strict" != unset ]]; then export EIGS_STRICT="$strict"; fi
            if [[ "$jit" == off ]]; then export EIGS_JIT_OFF=1; fi
            if [[ "$jit" == osr ]]; then export EIGS_JIT_OSR_THRESHOLD=1; fi
            mc_tmo 30 "$ROOT/build/$variant/test_missing_capability"
        ) > "$output" 2>&1 || rc=$?
        cat "$output"
        classification=0
        lsan_classify "$(cat "$output")" || classification=$?
        summary=$(tail -n 1 "$output")
        rm -f "$output"
        [[ "$rc" -eq 0 && "$classification" -eq 2 ]]
        [[ "$summary" =~ $summary_pattern ]]
        [[ $((BASH_REMATCH[1] + BASH_REMATCH[2])) -eq 40 ]]
        extra=0
        if [[ "$(uname -m)" == x86_64 && "$jit" != off && "${BASH_REMATCH[1]}" -gt 0 ]]; then extra=1; fi
        [[ "${BASH_REMATCH[3]}" -eq $((4 + 12 * BASH_REMATCH[1] + 2 * BASH_REMATCH[2] + (BASH_REMATCH[1] > 0) + extra)) ]]
        echo "PASS: missing capability strict=$strict jit=$jit"
    done
done
