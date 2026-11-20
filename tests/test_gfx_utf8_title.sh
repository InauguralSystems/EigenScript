#!/bin/bash
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
<<<<<<< HEAD
DISPLAY_NUM=
=======
>>>>>>> origin/main
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs-1681-title.XXXXXX")
export LC_ALL=C.UTF-8

SIGNAL_STATUS=
CLEANING=
signal_status() {
    case $1 in HUP) SIGNAL_STATUS=129;; INT) SIGNAL_STATUS=130;; TERM) SIGNAL_STATUS=143;; esac
}
wait_bounded() {
    pid=$1
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null || true
    n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 5 ]; do
        sleep 0.1
        n=$((n + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
}
cleanup() {
    [ -n "$CLEANING" ] && return
    CLEANING=1
    echo "GFX_SIGNAL_CLEANUP tmp=$TMP"
    if [ "${EIGS_SIGNAL_TEST_MOMENT:-}" = cleanup ]; then
        while [ -z "$SIGNAL_STATUS" ]; do sleep 0.1; done
    fi
    wait_bounded "${PROGRAM_PID:-}"
    PROGRAM_PID=
    wait_bounded "${XVFB_PID:-}"
    XVFB_PID=
    rm -rf "$TMP"
}
on_signal() {
    signal_status "$1"
    [ -n "$CLEANING" ] && return
    cleanup
    exit "$SIGNAL_STATUS"
}
on_exit() {
    status=$?
    cleanup
    [ -n "$SIGNAL_STATUS" ] && exit "$SIGNAL_STATUS"
    return "$status"
}
trap on_exit EXIT
trap 'on_signal HUP' HUP
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

echo "GFX_SIGNAL_READY tmp=$TMP"
if [ "${EIGS_SIGNAL_TEST_MOMENT:-}" = before-server ]; then
    while :; do sleep 1; done
fi

<<<<<<< HEAD
# -noreset (#2204): without it Xvfb resets whenever its last client
# disconnects, which happens between every two cases here. A case whose
# program connects during that reset dies with "SDL_Init failed: x11 not
# available"; a loaded box widens the window enough to hit it.
display_file="$TMP/display"
Xvfb -displayfd 3 -screen 0 640x480x24 -noreset >"$TMP/xvfb.log" 2>&1 3>"$display_file" &
XVFB_PID=$!
i=0
while [ "$i" -lt 100 ]; do
    kill -0 "$XVFB_PID" 2>/dev/null || break
    if [ -s "$display_file" ]; then
        DISPLAY_NUM=":$(sed -n '1p' "$display_file")"
        xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1 && break
    fi
    sleep 0.1
    i=$((i + 1))
done
if [ -z "$DISPLAY_NUM" ] || ! xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1; then
    echo "  FAIL: Xvfb did not become ready"
    cat "$TMP/xvfb.log"
    exit 1
fi
echo "GFX_SIGNAL_SERVER pid=$XVFB_PID"
if [ "${EIGS_SIGNAL_TEST_MOMENT:-}" = server ]; then
    while :; do sleep 1; done
fi
=======
# The server is started by tests/xvfb.sh, which keeps it from resetting when
# its last client leaves (#2215): a reset closes a handshake that is pending.
. "$ROOT/tests/xvfb.sh" || exit 1
xvfb_start || exit 1
>>>>>>> origin/main

# Each wait is bounded by a deadline, not a count of short sleeps: on a
# loaded box one xdotool or xprop call can take most of a fixed budget
# (#2204). Generous because a passing run never waits it out.
STEP_DEADLINE=${EIGS_TITLE_STEP_DEADLINE:-30}

case_number=0
passed_cases=0
print_summary() {
    failed_cases=$1
    echo "Tests: $case_number | Pass: $passed_cases | Fail: $failed_cases"
    if [ "$failed_cases" -eq 0 ]; then
        echo "All tests passed."
    else
        echo "Tests failed."
    fi
}

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
    echo "GFX_SIGNAL_CASE pid=$PROGRAM_PID"
    if [ "${EIGS_SIGNAL_TEST_MOMENT:-}" = case ]; then
        while :; do sleep 1; done
    fi

    timed_out=
    window_id=
    deadline=$((SECONDS + STEP_DEADLINE))
    while :; do
        # SDL may create an unmapped helper window for the process before its
        # mapped application window.  Taking xdotool's first result can pin
        # every later xprop poll to that property-less helper.  Restrict the
        # search to mapped/visible windows; there is no window manager here,
        # so this is the SDL top-level window rather than a frame window.
        window_id=$(DISPLAY="$DISPLAY_NUM" xdotool search --onlyvisible --pid "$PROGRAM_PID" 2>/dev/null | sed -n '1p')
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
    xprop_rc=not-run
    xprop_err="$TMP/xprop-$case_number.err"
    : >"$xprop_err"
    deadline=$((SECONDS + STEP_DEADLINE))
    while [ -n "$window_id" ]; do
        xprop_rc=0
        properties=$(xprop -display "$DISPLAY_NUM" -id "$window_id" 2>"$xprop_err") || xprop_rc=$?
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
        if [ -n "$timed_out" ]; then
            echo "  TIMEOUT: $timed_out"
            echo "  xprop rc: $xprop_rc"
            if [ -s "$xprop_err" ]; then
                sed 's/^/  xprop stderr: /' "$xprop_err"
            else
                echo "  xprop stderr: <empty>"
            fi
        fi
        echo "  FAIL: title properties for case $case_number"
        # The EigenScript fixture only checks that gfx_open succeeded.  Do
        # not repeat its independent green test_summary after this harness
        # has found a title failure: that made the final summary lie.
        sed '/^Tests: /d; /^All tests passed\.$/d' "$log"
        print_summary 1
        exit 1
    fi
    passed_cases=$((passed_cases + 1))
    echo "  PASS: title properties for case $case_number"
}

run_case 'eigs-1681 ASCII' '' 'eigs-1681 ASCII' STRING 1
run_case 'eigs-1681 — UTF-8' '' 'eigs-1681 — UTF-8' COMPOUND_TEXT 0
run_case 'DMG' 'DMG — 48 MHz — frame 7' 'DMG — 48 MHz — frame 7' COMPOUND_TEXT 0
run_case 'eigs-1681 — initial' 'eigs-1681 ASCII retitle' 'eigs-1681 ASCII retitle' STRING 1

echo "  PASS: all four ICCCM/EWMH title transitions"
print_summary 0
