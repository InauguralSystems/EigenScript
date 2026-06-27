#!/bin/bash
# Build eigenlsp under AddressSanitizer + UBSan and run the behavioral harness
# against it. test_lsp.py scans the LSP process's stderr and FAILS on any
# sanitizer report (leaks, UB, errors). This codifies the manual probe so the
# LSP can never regress into a sanitizer finding unnoticed — the eigenlsp
# binary is otherwise only compile-checked and behavior-tested without
# sanitizers, since `make asan` builds the interpreter, not the LSP.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$DIR/.."

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not available"
    exit 0
fi

echo "Building eigenlsp with -fsanitize=address,undefined ..."
make -C "$ROOT" lsp \
    CFLAGS="-fsanitize=address,undefined -g -O1 -Wall -Werror=implicit-function-declaration" \
    >/dev/null

export ASAN_OPTIONS=detect_leaks=1
export UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1
set +e
EIGENLSP="$ROOT/src/eigenlsp" python3 "$DIR/test_lsp.py"
rc=$?
set -e

# Restore a normal (non-sanitizer) eigenlsp so a local run doesn't leave an
# instrumented binary behind. Best-effort; CI discards the workspace anyway.
echo "Rebuilding normal eigenlsp ..."
make -C "$ROOT" lsp >/dev/null 2>&1 || true

exit $rc
