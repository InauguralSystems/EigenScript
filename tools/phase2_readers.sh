#!/usr/bin/env bash
# #1758 R1.6a: final readers through the no-SDL amalgamation, warnings fatal.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VARIANT=${1:-release}
case "$VARIANT" in release|asan) ;; *) echo "phase2-readers: FAIL unknown variant $VARIANT"; exit 2 ;; esac
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs-readers.XXXXXX") || { echo 'phase2-readers: FAIL mktemp'; exit 2; }
trap 'rm -rf "$TMP"' EXIT
fail() { echo "phase2-readers: FAIL $*"; exit 1; }
make -s -C "$ROOT" PHASE2_READERS_VARIANT="$VARIANT" phase2-readers-test > "$TMP/build" 2>&1
rc=$?
if [ "$rc" -ne 0 ] || grep -q 'warning:' "$TMP/build"; then
    cat "$TMP/build"
    rm -f "$ROOT/build/phase2/readers_$VARIANT"
    fail "build rc=$rc (all compiler warnings fail)"
fi
BIN="$ROOT/build/phase2/readers_$VARIANT"
[ -x "$BIN" ] || fail "missing binary $BIN"
if [ "$VARIANT" = asan ]; then
    ASAN_OPTIONS=detect_leaks=1 "$BIN" > "$TMP/out" 2> "$TMP/err"
    rc=$?
else
    "$BIN" > "$TMP/out" 2> "$TMP/err"
    rc=$?
fi
cat "$TMP/out"
if [ -s "$TMP/err" ]; then cat "$TMP/err"; fail 'reader fixture wrote stderr'; fi
[ "$rc" -eq 0 ] || fail "reader fixture rc=$rc"
[ "$(grep -c '^phase2-readers-test: PASS cases=[1-9][0-9]* forms=49 checks=[1-9][0-9]* failures=0$' "$TMP/out")" -eq 1 ] || fail 'missing unique complete PASS'
[ "$(wc -l < "$TMP/out" | tr -d ' ')" -eq 1 ] || fail 'unexpected fixture output'
checks=$(sed -n 's/^phase2-readers-test: PASS .* checks=\([0-9][0-9]*\) failures=0$/\1/p' "$TMP/out")
echo "phase2-readers: PASS variant=$VARIANT checks=$checks"
