#!/usr/bin/env bash
# Build only the auxiliary target, preserving the suite's interpreter alias.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
variant=
for candidate in "$ROOT"/build/*/eigenscript; do
    if [[ "$ROOT/src/eigenscript" -ef "$candidate" ]]; then
        variant=$(basename "$(dirname "$candidate")")
        break
    fi
done
if [[ -z "$variant" ]]; then
    variant=release
    echo "trace context: build.sh layout; using owning release source objects"
fi
make --no-print-directory -C "$ROOT" trace-context-test "TRACE_CONTEXT_VARIANT=$variant"
unset EIGS_TRACE EIGS_REPLAY EIGS_OBS_FORCE
# Direct fallback has no child deadline; local runs use an owned outer bound.
trace_tmo() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 20 "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout 20 "$@"
    else
        "$@"
    fi
}
out=$(mktemp)
trap 'rm -f "$out"' EXIT
rc=0
trace_tmo "$ROOT/build/$variant/test_trace_context" > "$out" 2>&1 || rc=$?
cat "$out"
source "$ROOT/tests/lsan_classify.sh"
classification=0
lsan_classify "$(cat "$out")" || classification=$?
if [[ "$rc" -ne 0 || "$classification" -ne 2 ]]; then
    echo "FAIL: trace context child rc=$rc sanitizer=$classification"
    exit 1
fi
summaries=$(grep -Fxc 'trace context: 41 passed, 0 failed (41 declared)' "$out" || true)
[[ "$summaries" -eq 1 ]] || exit 1
passes=$(grep -c '^PASS:' "$out" || true)
[[ "$passes" -eq 41 ]] || exit 1
if grep -q '^FAIL:' "$out"; then
    exit 1
fi
