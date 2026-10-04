#!/usr/bin/env bash
# Helper arithmetic and tiny successful VM entries, using the owning variant.
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
    echo "sandbox work: build.sh layout; separately built release-object check"
fi
make --no-print-directory -C "$ROOT" sandbox-work-test "SANDBOX_WORK_VARIANT=$variant"
work_tmo() {
    if command -v timeout >/dev/null 2>&1; then timeout 20 "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout 20 "$@"
    else "$@"
    fi
}
out=$(mktemp)
trap 'rm -f "$out"' EXIT
rc=0
work_tmo "$ROOT/build/$variant/test_sandbox_work_budget" > "$out" 2>&1 || rc=$?
cat "$out"
source "$ROOT/tests/lsan_classify.sh"
classification=0
lsan_classify "$(cat "$out")" || classification=$?
[[ "$rc" -eq 0 && "$classification" -eq 2 ]] || exit 1
[[ $(grep -Fxc 'PASS: sandbox work budget (26 assertions)' "$out") -eq 1 ]]
