#!/bin/bash
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DISPLAY_NUM=":$((90 + ($$ % 900)))"
TITLE='eigs-1681 — UTF-8'
export LC_ALL=C.UTF-8
XVFB_LOG=$(mktemp "${TMPDIR:-/tmp}/eigs-1681-xvfb.XXXXXX")
PROGRAM_LOG=$(mktemp "${TMPDIR:-/tmp}/eigs-1681-program.XXXXXX")

cleanup() {
    [ -n "${PROGRAM_PID:-}" ] && kill "$PROGRAM_PID" 2>/dev/null || true
    [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null || true
    [ -n "${PROGRAM_PID:-}" ] && wait "$PROGRAM_PID" 2>/dev/null || true
    [ -n "${XVFB_PID:-}" ] && wait "$XVFB_PID" 2>/dev/null || true
    rm -f "$XVFB_LOG" "$PROGRAM_LOG"
}
trap cleanup EXIT HUP INT TERM

Xvfb "$DISPLAY_NUM" -screen 0 640x480x24 >"$XVFB_LOG" 2>&1 &
XVFB_PID=$!
for _ in $(seq 1 100); do
    kill -0 "$XVFB_PID" 2>/dev/null || break
    xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1 && break
    sleep 0.1
done
if ! xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1; then
    echo "  FAIL: Xvfb did not become ready"
    cat "$XVFB_LOG"
    exit 1
fi

# C.UTF-8 supplies the POSIX locale environment an application must activate
# with setlocale(LC_CTYPE, "").  The parent implementation never activated it,
# so SDL published only a doubly encoded legacy WM_NAME and no _NET_WM_NAME.
DISPLAY="$DISPLAY_NUM" SDL_VIDEODRIVER=x11 \
    "$ROOT/src/eigenscript" "$ROOT/tests/test_gfx_utf8_title.eigs" \
    >"$PROGRAM_LOG" 2>&1 &
PROGRAM_PID=$!

WINDOW_ID=
for _ in $(seq 1 100); do
    WINDOW_ID=$(xwininfo -display "$DISPLAY_NUM" -root -tree 2>/dev/null |
        awk '/"eigs-1681 / { print $1; exit }')
    [ -n "$WINDOW_ID" ] && break
    kill -0 "$PROGRAM_PID" 2>/dev/null || break
    sleep 0.1
done

ACTUAL=
if [ -n "$WINDOW_ID" ]; then
    ACTUAL=$(xprop -display "$DISPLAY_NUM" -id "$WINDOW_ID" \
        -notype _NET_WM_NAME 2>/dev/null)
fi
EXPECTED="_NET_WM_NAME = \"$TITLE\""

wait "$PROGRAM_PID"
PROGRAM_RC=$?
PROGRAM_PID=

if [ "$PROGRAM_RC" -eq 0 ] && [ "$ACTUAL" = "$EXPECTED" ]; then
    echo "  PASS: xprop reads the UTF-8 title bytes from _NET_WM_NAME"
    exit 0
fi

echo "  FAIL: _NET_WM_NAME UTF-8 title (program rc=$PROGRAM_RC)"
printf '    expected: %s\n    actual:   %s\n' "$EXPECTED" "${ACTUAL:-<missing>}"
cat "$PROGRAM_LOG"
exit 1
