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
if [ ! -r "$FONT" ]; then
    echo "SKIP: CI TTF font is not installed: $FONT"
    exit 0
fi
if ! command -v Xvfb >/dev/null 2>&1 || ! command -v xdpyinfo >/dev/null 2>&1; then
    echo "SKIP: Xvfb or xdpyinfo is unavailable"
    exit 0
fi

. "$ROOT/tests/xvfb.sh" || exit 1
xvfb_start || exit 1

OUTPUT=$(DISPLAY="$DISPLAY_NUM" SDL_VIDEODRIVER=x11 EIGS_GFX_FONT="$FONT" \
    "$ROOT/src/eigenscript" "$ROOT/tests/test_hex_view_ttf.eigs" 2>&1)
RC=$?
printf '%s\n' "$OUTPUT"
[ "$RC" -eq 0 ] || exit "$RC"
if printf '%s\n' "$OUTPUT" | grep -q '^SKIP:'; then
    exit 0
fi
printf '%s\n' "$OUTPUT" | grep -q 'Tests: 95 | Pass: 95 | Fail: 0' || {
    echo "FAIL: TTF render-decode did not report all 95 checks"
    exit 1
}
echo "PASS: TTF render-decode found in-cell ink for bytes 33..126"
