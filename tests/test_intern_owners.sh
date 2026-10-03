#!/usr/bin/env bash
# Strict, owning-variant structural oracle; no bytecode/known fault fixture.
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
    echo "intern owner contract: build.sh layout; separately built release-object contract"
fi
make --no-print-directory -C "$ROOT" intern-owner-test "INTERN_OWNER_VARIANT=$variant"
unset EIGS_OBS_FORCE EIGS_TRACE EIGS_REPLAY
owned=$(mktemp -d)
trap 'rm -rf "$owned"' EXIT
rc=0
# timeout/gtimeout supplies a child deadline when available. The direct
# fallback has no intrinsic deadline; local validation has an owned parent.
intern_tmo() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 20 "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout 20 "$@"
    else
        "$@"
    fi
}
intern_tmo "$ROOT/build/$variant/test_intern_owners" > "$owned/output" 2>&1 || rc=$?
cat "$owned/output"
source "$ROOT/tests/lsan_classify.sh"
classification=0
lsan_classify "$(cat "$owned/output")" || classification=$?
if [[ "$rc" -ne 0 || "$classification" -ne 2 ]]; then
    exit 1
fi
[[ $(grep -c '^PASS:' "$owned/output") -eq 32 ]]
[[ $(grep -Fxc 'intern owner structural: 32 passed, 0 failed (32 declared)' "$owned/output") -eq 1 ]]
[[ $(grep -Ec '^layout: Value=[1-9][0-9]* Env=[1-9][0-9]* fn-param-owner=[0-9]+ dict-owner=[0-9]+ private-flag=[0-9]+$' "$owned/output") -eq 1 ]]
