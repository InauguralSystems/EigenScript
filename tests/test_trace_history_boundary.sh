#!/usr/bin/env bash
# Ordinary fixed-size direct-producer oracle, against the owning runtime.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
EIGS=${EIGENSCRIPT:-$ROOT/src/eigenscript}
variant=
for candidate in "$ROOT"/build/*/eigenscript; do
    if [[ "$EIGS" -ef "$candidate" ]]; then
        variant=$(basename "$(dirname "$candidate")")
        break
    fi
done
if [[ -z "$variant" ]]; then
    variant=release
    echo "history boundary: no matching CLI variant (build.sh layout); using release"
fi
make --no-print-directory -C "$ROOT" trace-history-boundary-test "HISTORY_BOUNDARY_VARIANT=$variant"
unset EIGS_TRACE EIGS_REPLAY EIGS_OBS_FORCE
export EIGS_OCC_WINDOW=4
out=$(mktemp)
trap 'rm -f "$out"' EXIT
rc=0
"$ROOT/build/$variant/test_trace_history_boundary" > "$out" 2>&1 || rc=$?
cat "$out"
source "$ROOT/tests/lsan_classify.sh"
classification=0
lsan_classify "$(cat "$out")" || classification=$?
[[ "$rc" -eq 0 && "$classification" -eq 2 ]] || exit 1
[[ $(grep -Fxc 'history boundary: 32 passed, 0 failed (32 declared)' "$out") -eq 1 ]] || exit 1
[[ $(grep -c '^PASS: ' "$out") -eq 32 ]] || exit 1
if grep -q '^FAIL:' "$out"; then exit 1; fi
