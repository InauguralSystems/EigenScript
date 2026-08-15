#!/bin/bash
# Wrapper for the LSP behavioral tests (test_lsp.py). Builds the eigenlsp
# binary if needed and skips cleanly when python3 or the build is
# unavailable, so the suite stays green on minimal environments.
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP: python3 not available — LSP tests skipped"
    exit 0
fi

LSP="$ROOT/src/eigenlsp"
# Presence is not freshness: `make` does not build eigenlsp, so this section
# could drive a binary from an earlier tree. See tests/aux_binary.sh.
. "$TESTS_DIR/aux_binary.sh"
aux_binary_fresh "$LSP" lsp eigenlsp LSP
case $? in
    2) exit 0 ;;
    1) exit 1 ;;
esac

EIGENLSP="$LSP" python3 "$TESTS_DIR/test_lsp.py"
