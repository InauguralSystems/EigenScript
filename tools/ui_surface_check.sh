#!/usr/bin/env bash
# Source enrollment is separate from the real SDL input check.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
case "${1:-}" in
    "") exec python3 "$ROOT/tools/ui_surface_check.py" ;;
    --selftest) exec python3 "$ROOT/tools/ui_surface_check.py" --selftest ;;
    --gfx-input)
        python3 "$ROOT/tools/ui_surface_check.py"
        ulimit -v 1500000
        make --no-print-directory -C "$ROOT" build
        make --no-print-directory -C "$ROOT" ui-sdl-input-gfx
        native_evidence=$(mktemp -d "${TMPDIR:-/tmp}/eigs-ui-native.XXXXXX")
        echo "UI native input evidence: $native_evidence/capture"
        python3 "$ROOT/tests/ui_native_input.py" --binary "$ROOT/src/eigenscript" --output "$native_evidence/capture"
        ;;
    *) echo "usage: tools/ui_surface_check.sh [--gfx-input|--selftest]" >&2; exit 2 ;;
esac
