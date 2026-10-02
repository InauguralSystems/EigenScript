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

LSP="$ROOT/build/asan/lsp/eigenlsp"
echo "Building eigenlsp with -fsanitize=address,undefined ..."
make -C "$ROOT" lsp-asan lsp-arming-test LSP_ARMING_VARIANT=asan >/dev/null

# Do not accept a behavioral pass from an accidentally reused release binary.
# This assertion is deliberately independent of make's freshness decision: a
# planted newer release src/eigenlsp exposed the old CFLAGS-override hole.
if ! nm "$LSP" 2>/dev/null | grep -q '__asan_init'; then
    echo "FAIL: $LSP is not AddressSanitizer-instrumented (__asan_init absent)"
    exit 1
fi

export ASAN_OPTIONS=detect_leaks=1
export UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1
set +e
EIGENLSP="$LSP" EIGENLSP_ARMING="$ROOT/build/asan/test_lsp_arming" python3 "$DIR/test_lsp.py"
rc=$?
set -e

exit $rc
