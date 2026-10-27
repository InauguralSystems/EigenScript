#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARENT=${1:-}
TEMP=
cleanup() { [ -z "$TEMP" ] || rm -rf "$TEMP"; }
trap cleanup EXIT
if [ -z "$PARENT" ]; then
    # PR #1989 branched from this main commit. Pinning the incumbent makes the
    # accepted delta stable even after main advances.
    PARENT_REF=${FMT_PARENT_REF:-dffac84}
    TEMP=$(mktemp -d /tmp/eigs-fmt-parent-XXXXXX)
    git -C "$ROOT" archive "$PARENT_REF" | tar -x -C "$TEMP"
    make -C "$TEMP" -j2 >/dev/null
    PARENT="$TEMP/src/eigenscript"
fi
python3 "$ROOT/tests/fmt_parent_differential.py" \
    "$PARENT" "$ROOT/src/eigenscript" "$ROOT"
