#!/bin/bash
# Wrapper for the DAP behavioral tests (test_dap.py, #539 v3). Builds the
# eigsdap binary if needed and skips cleanly when python3 or the builds
# are unavailable, so the suite stays green on minimal environments.
# Mirrors test_lsp.sh.
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP: python3 not available — DAP tests skipped"
    exit 0
fi

EIGS="$ROOT/src/eigenscript"
if [ ! -x "$EIGS" ]; then
    echo "  SKIP: eigenscript not built — DAP tests skipped"
    exit 0
fi

DAP="$ROOT/src/eigsdap"
if [ ! -x "$DAP" ]; then
    ( cd "$ROOT" && make dap ) >/dev/null 2>&1
fi
if [ ! -x "$DAP" ]; then
    echo "  SKIP: eigsdap not built — DAP tests skipped"
    exit 0
fi

EIGSDAP="$DAP" EIGENSCRIPT="$EIGS" python3 "$TESTS_DIR/test_dap.py"
