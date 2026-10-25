#!/usr/bin/env bash
# #1758 R1.6a: final readers through the no-SDL amalgamation, warnings fatal.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VARIANT=${1:-release}
FIXTURE=${2:-readers}
LABEL=phase2-readers
case "$FIXTURE" in
    readers) ;;
    num_text) LABEL=phase2-num-text ;;
    const_dedup_bits) LABEL=phase2-const-dedup ;;
    q7_readers) LABEL=phase2-q7-readers ;;
    gfx_audio_boundary) LABEL=phase2-gfx-audio ;;
    gfx_byte_boundary) LABEL=phase2-gfx-byte ;;
    net_byte_boundary) LABEL=phase2-net-boundary ;;
    embed_buffer_get_raw) LABEL=phase2-embed-buffer-get ;;
    *) echo "phase2-readers: FAIL unknown fixture $FIXTURE"; exit 2 ;;
esac
[ -f "$ROOT/tests/phase2/$FIXTURE.c" ] || { echo "$LABEL: FAIL missing tests/phase2/$FIXTURE.c"; exit 1; }
case "$VARIANT" in release|asan) ;; *) echo "phase2-readers: FAIL unknown variant $VARIANT"; exit 2 ;; esac
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs-readers.XXXXXX") || { echo 'phase2-readers: FAIL mktemp'; exit 2; }
trap 'rm -rf "$TMP"' EXIT
fail() { echo "$LABEL: FAIL $*"; exit 1; }
make -s -C "$ROOT" PHASE2_READERS_VARIANT="$VARIANT" PHASE2_READERS_FIXTURE="$FIXTURE" phase2-readers-test > "$TMP/build" 2>&1
rc=$?
if [ "$rc" -ne 0 ] || grep -q 'warning:' "$TMP/build"; then
    cat "$TMP/build"
    rm -f "$ROOT/build/phase2/${FIXTURE}_$VARIANT"
    fail "build rc=$rc (all compiler warnings fail)"
fi
BIN="$ROOT/build/phase2/${FIXTURE}_$VARIANT"
[ -x "$BIN" ] || fail "missing binary $BIN"
if [ "$VARIANT" = asan ]; then
    ASAN_OPTIONS=detect_leaks=1 env -u XAUTHORITY DISPLAY=:99 SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy "$BIN" > "$TMP/out" 2> "$TMP/err"
    rc=$?
else
    ( case "$FIXTURE" in gfx_*_boundary) ulimit -v 1500000 ;; esac;
      env -u XAUTHORITY DISPLAY=:99 SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy "$BIN" ) > "$TMP/out" 2> "$TMP/err"
    rc=$?
fi
cat "$TMP/out"
if [ -s "$TMP/err" ]; then cat "$TMP/err"; fail 'reader fixture wrote stderr'; fi
[ "$rc" -eq 0 ] || fail "reader fixture rc=$rc"
if [ "$FIXTURE" = num_text ]; then
    [ "$(grep -cE '^phase2-num-text-test: PASS cases=54 checks=1038 failures=0$' "$TMP/out")" -eq 1 ] || fail 'missing unique complete number text PASS'
    [ "$(wc -l < "$TMP/out" | tr -d ' ')" -eq 1 ] || fail 'unexpected number text output'
    echo "$LABEL: PASS variant=$VARIANT"
    exit 0
fi
if [ "$FIXTURE" = const_dedup_bits ]; then
    [ "$(grep -cE '^phase2-const-dedup-test: PASS checks=8 failures=0$' "$TMP/out")" -eq 1 ] || fail 'missing unique complete const dedup PASS'
    [ "$(wc -l < "$TMP/out" | tr -d ' ')" -eq 1 ] || fail 'unexpected const dedup output'
    echo "$LABEL: PASS variant=$VARIANT"
    exit 0
fi
if [ "$FIXTURE" = embed_buffer_get_raw ]; then
    [ "$(grep -cE '^phase2-embed-buffer: PASS checks=36 failures=0$' "$TMP/out")" -eq 1 ] || fail 'missing unique complete getter PASS'
    [ "$(wc -l < "$TMP/out" | tr -d ' ')" -eq 1 ] || fail 'unexpected getter output'
    echo "$LABEL: PASS variant=$VARIANT"
    exit 0
fi
if [ "$FIXTURE" = net_byte_boundary ]; then
    [ "$(grep -cE '^phase2-net-byte: PASS checks=72 failures=0$' "$TMP/out")" -eq 1 ] || fail 'missing unique complete net-byte-boundary PASS'
    [ "$(wc -l < "$TMP/out" | tr -d ' ')" -eq 1 ] || fail 'unexpected net-byte-boundary fixture output'
    echo "$LABEL: PASS variant=$VARIANT"
    exit 0
fi
if [ "$FIXTURE" = gfx_byte_boundary ]; then
    [ "$(grep -cE '^phase2-gfx-byte-test: PASS checks=247 failures=0$' "$TMP/out")" -eq 1 ] || fail 'missing unique complete byte-boundary PASS'
    [ "$(wc -l < "$TMP/out" | tr -d ' ')" -eq 1 ] || fail 'unexpected byte-boundary fixture output'
    echo "$LABEL: PASS variant=$VARIANT"
    exit 0
fi
if [ "$FIXTURE" = gfx_audio_boundary ]; then
    [ "$(grep -cE '^phase2-gfx-audio-test: PASS checks=44 failures=0$' "$TMP/out")" -eq 1 ] || fail 'missing unique complete audio-boundary PASS'
    [ "$(wc -l < "$TMP/out" | tr -d ' ')" -eq 1 ] || fail 'unexpected audio-boundary fixture output'
    echo "$LABEL: PASS variant=$VARIANT"
    exit 0
fi
if [ "$FIXTURE" = q7_readers ]; then
    [ "$(grep -cE '^phase2-q7-test: PASS checks=46 failures=0$' "$TMP/out")" -eq 1 ] || fail 'missing unique complete Q7 PASS'
    [ "$(wc -l < "$TMP/out" | tr -d ' ')" -eq 1 ] || fail 'unexpected Q7 fixture output'
    echo "$LABEL: PASS variant=$VARIANT"
    exit 0
fi
[ "$(grep -c '^phase2-readers-test: PASS cases=[1-9][0-9]* forms=49 checks=[1-9][0-9]* failures=0$' "$TMP/out")" -eq 1 ] || fail 'missing unique complete PASS'
[ "$(wc -l < "$TMP/out" | tr -d ' ')" -eq 1 ] || fail 'unexpected fixture output'
checks=$(sed -n 's/^phase2-readers-test: PASS .* checks=\([0-9][0-9]*\) failures=0$/\1/p' "$TMP/out")
echo "phase2-readers: PASS variant=$VARIANT checks=$checks"
