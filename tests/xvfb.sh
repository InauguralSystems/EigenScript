#!/bin/bash
# Shared Xvfb startup for tests that require the X11 video driver.
# The caller owns XVFB_PID and must stop it from its EXIT trap.

xvfb_start() {
    local display_file="$TMP/xvfb-display" display_number i

    : >"$display_file"
    Xvfb -displayfd 3 -screen 0 640x480x24 -noreset -audit 4 \
        3>"$display_file" >"$TMP/xvfb.log" 2>&1 &
    XVFB_PID=$!

    i=0
    while [ "$i" -lt 100 ]; do
        kill -0 "$XVFB_PID" 2>/dev/null || break
        [ -s "$display_file" ] && break
        sleep 0.1
        i=$((i + 1))
    done
    display_number=$(sed -n '1p' "$display_file")
    case "$display_number" in
        ''|*[!0-9]*)
            echo "  FAIL: Xvfb did not report a display"
            cat "$TMP/xvfb.log"
            return 1
            ;;
    esac
    DISPLAY_NUM=:$display_number

    i=0
    while [ "$i" -lt 100 ]; do
        kill -0 "$XVFB_PID" 2>/dev/null || break
        xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1 && return 0
        sleep 0.1
        i=$((i + 1))
    done
    echo "  FAIL: Xvfb did not become ready"
    cat "$TMP/xvfb.log"
    return 1
}
