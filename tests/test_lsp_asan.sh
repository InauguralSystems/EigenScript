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

#
# LSP_ASAN_VARIANT picks the ASan runtime the LSP links against (#2277):
# `asan` (default) or `asan-server`. CI's ASan shards pass `asan-server`, the
# variant they already built, so this step links instead of compiling a
# second sanitizer variant. The arming witness uses the same variant.
#
# A missing python3 is a FAILURE, not a skip: CI records this script as the
# one place the LSP runs under a sanitizer (the shard receipt's lsp_asan=yes),
# and an exit 0 that ran nothing would make that receipt a lie.

if ! command -v python3 >/dev/null 2>&1; then
    echo "FAIL: python3 not available — the LSP sanitizer behaviour test cannot run"
    exit 1
fi

VARIANT="${LSP_ASAN_VARIANT:-asan}"
case "$VARIANT" in
    asan|asan-server) ;;
    *) echo "FAIL: LSP_ASAN_VARIANT='$VARIANT' is not an ASan variant (asan, asan-server)"; exit 1 ;;
esac

LSP="$ROOT/build/$VARIANT/lsp/eigenlsp"
ARMING="$ROOT/build/$VARIANT/test_lsp_arming"
echo "Building eigenlsp with -fsanitize=address,undefined against the $VARIANT runtime objects ..."
make -C "$ROOT" lsp-asan lsp-arming-test LSP_ASAN_VARIANT="$VARIANT" LSP_ARMING_VARIANT="$VARIANT" >/dev/null

# Do not accept a behavioral pass from an accidentally reused release binary.
# This assertion is deliberately independent of make's freshness decision: a
# planted newer release src/eigenlsp exposed the old CFLAGS-override hole.
for bin in "$LSP" "$ARMING"; do
    if ! nm "$bin" 2>/dev/null | grep -q '__asan_init'; then
        echo "FAIL: $bin is not AddressSanitizer-instrumented (__asan_init absent)"
        exit 1
    fi
done

export ASAN_OPTIONS=detect_leaks=1
export UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1
set +e
EIGENLSP="$LSP" EIGENLSP_ARMING="$ARMING" python3 "$DIR/test_lsp.py"
rc=$?
set -e

exit $rc
