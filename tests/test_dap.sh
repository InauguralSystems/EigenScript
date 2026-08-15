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
# Presence is not freshness, and neither is the version string below: both
# binaries read 0.39.0 while their sources differed by a day when this bit
# on the LSP side. See tests/aux_binary.sh.
. "$TESTS_DIR/aux_binary.sh"
aux_binary_fresh "$DAP" dap eigsdap DAP
case $? in
    2) exit 0 ;;
    1) exit 1 ;;
esac

# #825: a version-skewed eigsdap makes the #411 tape gate refuse every
# tape and the 18 downstream failures blame DAP behavior. Kept as a second,
# coarser net: it still catches a binary carried across a release bump from
# outside the tree, which an mtime check cannot see. (An eigsdap predating
# --version prints nothing on the EOF'd stdin and skips this check.)
DAP_VER="$("$DAP" --version </dev/null 2>/dev/null)"
EIGS_VER="$("$EIGS" --version 2>/dev/null)"
if [ -n "$DAP_VER" ] && [ "$DAP_VER" != "$EIGS_VER" ]; then
    echo "  FAIL: eigsdap is $DAP_VER but the runtime is $EIGS_VER — stale binary; run 'make dap' (#825)"
    exit 1
fi

EIGSDAP="$DAP" EIGENSCRIPT="$EIGS" python3 "$TESTS_DIR/test_dap.py"
