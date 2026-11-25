#!/bin/bash
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs-1646-ttf.XXXXXX")
XVFB_PID=
cleanup() {
    if [ -n "$XVFB_PID" ]; then
        kill "$XVFB_PID" 2>/dev/null || true
        wait "$XVFB_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM

FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
fail_or_skip() {
    echo "SKIP: $1"
    if [ "${EIGS_FAIL_ON_SKIP:-0}" = 1 ]; then
        echo "FAIL: hosted TTF check may not skip"
        exit 1
    fi
    exit 0
}
if [ ! -r "$FONT" ]; then
    fail_or_skip "CI TTF font is not installed: $FONT"
fi
if ! command -v Xvfb >/dev/null 2>&1 || ! command -v xdpyinfo >/dev/null 2>&1; then
    fail_or_skip "Xvfb or xdpyinfo is unavailable"
fi

. "$ROOT/tests/xvfb.sh" || exit 1
xvfb_start || exit 1

OUTPUT=$(DISPLAY="$DISPLAY_NUM" SDL_VIDEODRIVER=x11 EIGS_GFX_FONT="$FONT" \
    "$ROOT/src/eigenscript" "$ROOT/tests/test_hex_view_ttf.eigs" 2>&1)
RC=$?
printf '%s\n' "$OUTPUT"
. "$ROOT/tests/lsan_classify.sh" || exit 1
lsan_classify "$OUTPUT"; SAN_CLASS=$?
if [ "$SAN_CLASS" -eq 1 ]; then
    echo "FAIL: sanitizer diagnostic in TTF render output"
    exit 1
fi
[ "$RC" -eq 0 ] || exit "$RC"
if printf '%s\n' "$OUTPUT" | grep -q '^SKIP:'; then
    fail_or_skip "EigenScript TTF fixture skipped"
fi
printf '%s\n' "$OUTPUT" | grep -q 'Tests: 97 | Pass: 97 | Fail: 0' || {
    echo "FAIL: TTF render-decode did not report all 97 checks"
    exit 1
}
echo "PASS: TTF render-decode found in-cell ink for bytes 33..126"
