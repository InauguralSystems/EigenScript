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
    echo "trace correspondence: build.sh layout; using owning release source objects"
fi
make --no-print-directory -C "$ROOT" trace-correspondence-test "TRACE_CORRESPONDENCE_VARIANT=$variant"
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
trace_tmo "$ROOT/build/$variant/test_trace_correspondence" > "$out" 2>&1 || rc=$?
cat "$out"
source "$ROOT/tests/lsan_classify.sh"
classification=0
lsan_classify "$(cat "$out")" || classification=$?
if [[ "$rc" -ne 0 || "$classification" -ne 2 ]]; then
    echo "FAIL: trace correspondence child rc=$rc sanitizer=$classification"
    exit 1
fi
summaries=$(grep -Fxc 'trace correspondence: 31 passed, 0 failed (31 declared)' "$out" || true)
[[ "$summaries" -eq 1 ]] || exit 1
passes=$(grep -c '^PASS:' "$out" || true)
[[ "$passes" -eq 31 ]] || exit 1
if grep -q '^FAIL:' "$out"; then
    exit 1
fi
recorded=$(sed -n 's/^transcript record: //p' "$out")
replayed=$(sed -n 's/^transcript replay: //p' "$out")
if [[ "$recorded" != '11 12 21 22' || "$replayed" != "$recorded" ]]; then
    echo "FAIL: ordinary record/replay transcript differs or has wrong population"
    exit 1
fi
