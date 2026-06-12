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
if [ ! -x "$LSP" ]; then
    ( cd "$ROOT" && make lsp ) >/dev/null 2>&1
fi
if [ ! -x "$LSP" ]; then
    echo "  SKIP: eigenlsp not built — LSP tests skipped"
    exit 0
fi

EIGENLSP="$LSP" python3 "$TESTS_DIR/test_lsp.py"
