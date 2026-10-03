#!/usr/bin/env bash
# Ordinary acyclic live-owner oracle; direct fallback has no child deadline.
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
    echo "arena promotion: no matching CLI variant (build.sh layout); using release"
fi
make --no-print-directory -C "$ROOT" arena-promotion-ordinary-test "ARENA_PROMOTION_VARIANT=$variant"
arena_tmo() {
    if command -v timeout >/dev/null 2>&1; then timeout 20 "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout 20 "$@"
    else "$@"
    fi
}
out=$(mktemp)
trap 'rm -f "$out"' EXIT
rc=0
arena_tmo "$ROOT/build/$variant/test_arena_promotion_ordinary" > "$out" 2>&1 || rc=$?
cat "$out"
source "$ROOT/tests/lsan_classify.sh"
classification=0
lsan_classify "$(cat "$out")" || classification=$?
[[ "$rc" -eq 0 && "$classification" -eq 2 ]] || exit 1
[[ $(grep -Fxc 'ordinary arena promotion: 20 passed, 0 failed (20 declared)' "$out") -eq 1 ]] || exit 1
[[ $(grep -c '^PASS: ' "$out") -eq 20 ]] || exit 1
if grep -q '^FAIL:' "$out"; then exit 1; fi
