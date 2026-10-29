#!/usr/bin/env bash
# Build against the suite's owning runtime variant, like test_embed_observer.sh.
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
    echo "embed multi-attach: build.sh layout; using release objects"
fi

make --no-print-directory -C "$ROOT" embed-multiattach-test \
    "EMBED_MULTIATTACH_VARIANT=$variant"
out=$(mktemp)
trap 'rm -f "$out"' EXIT
rc=0
"$ROOT/build/$variant/test_embed_multiattach" >"$out" 2>&1 || rc=$?
cat "$out"

expected=$(printf '17\n29\nthread-a\n3')
actual=$(cat "$out")
if [[ "$rc" -eq 0 && "$actual" == "$expected" ]]; then
    echo "PASS: embed multi-attach preserves dict keys, global bindings, and builtins"
else
    echo "FAIL: embed multi-attach rc=$rc (expected exact four-line output)"
    exit 1
fi
