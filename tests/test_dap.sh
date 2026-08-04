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

# #825: a version-skewed eigsdap makes the #411 tape gate refuse every
# tape and the 18 downstream failures blame DAP behavior. Name the real
# cause up front. (An eigsdap predating --version prints nothing on the
# EOF'd stdin and skips this check.)
DAP_VER="$("$DAP" --version </dev/null 2>/dev/null)"
EIGS_VER="$("$EIGS" --version 2>/dev/null)"
if [ -n "$DAP_VER" ] && [ "$DAP_VER" != "$EIGS_VER" ]; then
    echo "  FAIL: eigsdap is $DAP_VER but the runtime is $EIGS_VER — stale binary; run 'make dap' (#825)"
    exit 1
fi

EIGSDAP="$DAP" EIGENSCRIPT="$EIGS" python3 "$TESTS_DIR/test_dap.py"
