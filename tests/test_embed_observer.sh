#!/usr/bin/env bash
# Hermetic C contract against the same runtime (including sanitizer) as the
# suite. Build only the auxiliary file target, which never relinks the CLI.
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
    # No build/<variant>/eigenscript hard-links to src/eigenscript: this is the
    # build.sh layout (the linux/macos CI lanes), which compiles src/eigenscript
    # as a real file. The observer contract is variant-independent (no sanitizer
    # semantics), so build and test the release objects. On the sanitizer suite
    # the hard link above resolves to "asan" and is used instead. (#1038, mirrors
    # the embed_roads build-layout fix.)
    variant=release
    echo "observer contract: no matching CLI variant (build.sh layout); using release"
fi
make --no-print-directory -C "$ROOT" embed-observer-test "EMBED_OBSERVER_VARIANT=$variant"
unset EIGS_OBS_FORCE EIGS_TRACE EIGS_REPLAY
out=$(mktemp)
trap 'rm -f "$out"' EXIT
rc=0
EIGS_OBS_GATE_STATS=1 "$ROOT/build/$variant/test_embed_observer" > "$out" 2>&1 || rc=$?
cat "$out"
# Strict: reject sanitizer diagnostics even at rc=0. The shared classifier
# distinguishes leak/hard/none; this new harness tolerates neither kind.
source "$ROOT/tests/lsan_classify.sh"
classification=0
lsan_classify "$(cat "$out")" || classification=$?
if [[ "$rc" -ne 0 || "$classification" -ne 2 ]]; then
    exit 1
fi
grep -q '^embed observer: 28 passed, 0 failed$' "$out"
grep -q '^embed obs-gate: unobserved$' "$out"
grep -q '^obs-gate: unobserved ' "$out"
