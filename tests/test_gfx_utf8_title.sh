#!/bin/bash
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DISPLAY_NUM=":$((90 + ($$ % 900)))"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs-1681-title.XXXXXX")
export LC_ALL=C.UTF-8

cleanup() {
    [ -n "${PROGRAM_PID:-}" ] && kill "$PROGRAM_PID" 2>/dev/null || true
    [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null || true
    [ -n "${PROGRAM_PID:-}" ] && wait "$PROGRAM_PID" 2>/dev/null || true
    [ -n "${XVFB_PID:-}" ] && wait "$XVFB_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM

# -noreset (#2204): without it Xvfb resets whenever its last client
# disconnects, which happens between every two cases here. A case whose
# program connects during that reset dies with "SDL_Init failed: x11 not
# available"; a loaded box widens the window enough to hit it.
Xvfb "$DISPLAY_NUM" -screen 0 640x480x24 -noreset >"$TMP/xvfb.log" 2>&1 &
XVFB_PID=$!
i=0
while [ "$i" -lt 100 ]; do
    kill -0 "$XVFB_PID" 2>/dev/null || break
    xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1 && break
    sleep 0.1
    i=$((i + 1))
done
if ! xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1; then
    echo "  FAIL: Xvfb did not become ready"
    cat "$TMP/xvfb.log"
    exit 1
fi

# Each wait is bounded by a deadline, not a count of short sleeps: on a
# loaded box one xdotool or xprop call can take most of a fixed budget
# (#2204). Generous because a passing run never waits it out.
STEP_DEADLINE=${EIGS_TITLE_STEP_DEADLINE:-30}

case_number=0
run_case() {
    initial=$1 updated=$2 expected=$3 legacy_type=$4 require_xdotool=$5
    case_number=$((case_number + 1))
    log="$TMP/program-$case_number.log"
    release="$TMP/release-$case_number"
    EIGS_INITIAL_TITLE="$initial" EIGS_UPDATED_TITLE="$updated" \
        EIGS_RELEASE_FILE="$release" \
        DISPLAY="$DISPLAY_NUM" SDL_VIDEODRIVER=x11 \
        "$ROOT/src/eigenscript" "$ROOT/tests/test_gfx_utf8_title.eigs" \
        >"$log" 2>&1 &
    PROGRAM_PID=$!

    timed_out=
    window_id=
    deadline=$((SECONDS + STEP_DEADLINE))
    while :; do
        window_id=$(DISPLAY="$DISPLAY_NUM" xdotool search --pid "$PROGRAM_PID" 2>/dev/null | sed -n '1p')
        [ -n "$window_id" ] && break
        if ! kill -0 "$PROGRAM_PID" 2>/dev/null; then
            timed_out="window: the program exited before its window appeared"
            break
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
            timed_out="window: no window for the program after ${STEP_DEADLINE}s"
            break
        fi
        sleep 0.1
    done

    properties=
    deadline=$((SECONDS + STEP_DEADLINE))
    while [ -n "$window_id" ]; do
        properties=$(xprop -display "$DISPLAY_NUM" -id "$window_id" 2>/dev/null)
        printf '%s\n' "$properties" | grep -Fq "WM_NAME($legacy_type) = \"$expected\"" &&
            printf '%s\n' "$properties" | grep -Fq "_NET_WM_NAME(UTF8_STRING) = \"$expected\"" && break
        if [ "$SECONDS" -ge "$deadline" ]; then
            timed_out="title: properties did not reach the expected title within ${STEP_DEADLINE}s"
            break
        fi
        sleep 0.1
    done

    echo "case $case_number: initial='$initial' updated='${updated:-<none>}'"
    printf '%s\n' "${properties:-<no xprop output>}" | sed 's/^/  /'

    failed=0
    printf '%s\n' "$properties" | grep -Fq "WM_NAME($legacy_type) = \"$expected\"" || failed=1
    printf '%s\n' "$properties" | grep -Fq "_NET_WM_NAME(UTF8_STRING) = \"$expected\"" || failed=1
    if [ "$require_xdotool" = 1 ] &&
       ! LC_ALL=C DISPLAY="$DISPLAY_NUM" xdotool search --name "^$expected$" >/dev/null 2>&1; then
        failed=1
    fi

    # The program holds its window until released; SIGTERM alone would not
    # end it early, because SDL turns it into a quit event.
    : >"$release"
    wait "$PROGRAM_PID" 2>/dev/null || true
    PROGRAM_PID=
    if [ "$failed" -ne 0 ]; then
        [ -n "$timed_out" ] && echo "  TIMEOUT: $timed_out"
        echo "  FAIL: title properties for case $case_number"
        cat "$log"
        exit 1
    fi
    echo "  PASS: title properties for case $case_number"
}

run_case 'eigs-1681 ASCII' '' 'eigs-1681 ASCII' STRING 1
run_case 'eigs-1681 — UTF-8' '' 'eigs-1681 — UTF-8' COMPOUND_TEXT 0
run_case 'DMG' 'DMG — 48 MHz — frame 7' 'DMG — 48 MHz — frame 7' COMPOUND_TEXT 0
run_case 'eigs-1681 — initial' 'eigs-1681 ASCII retitle' 'eigs-1681 ASCII retitle' STRING 1

echo "  PASS: all four ICCCM/EWMH title transitions"
