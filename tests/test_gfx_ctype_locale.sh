#!/bin/bash
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# Helper C is compiled with the repo's mandatory flags, as the other C-building
# tests do; CI's compiler guard rejects a compile without them.
WERROR_FLAGS_FILE="$ROOT/tools/werror_flags.txt"
. "$ROOT/tools/read_werror_flags.sh" || exit 1
DISPLAY_NUM=
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs-1681-ctype.XXXXXX")
SIGNAL_STATUS=
CLEANING=
PROGRAM_PID=
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
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}
cleanup() {
    [ -n "$CLEANING" ] && return
    CLEANING=1
    echo "GFX_SIGNAL_CLEANUP tmp=$TMP"
    if [ "${EIGS_SIGNAL_TEST_MOMENT:-}" = cleanup ]; then
        while [ -z "$SIGNAL_STATUS" ]; do sleep 0.1; done
    fi
    wait_bounded "$PROGRAM_PID"
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
if [ "${EIGS_SIGNAL_TEST_MOMENT:-}" = before-server ]; then while :; do sleep 1; done; fi

display_file="$TMP/display"
Xvfb -displayfd 3 -screen 0 640x480x24 >"$TMP/xvfb.log" 2>&1 3>"$display_file" &
XVFB_PID=$!
for _ in $(seq 1 100); do
    if [ -s "$display_file" ]; then
        DISPLAY_NUM=":$(sed -n '1p' "$display_file")"
        xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1 && break
    fi
    kill -0 "$XVFB_PID" 2>/dev/null || break
    sleep 0.1
done
if [ -z "$DISPLAY_NUM" ] || ! xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1; then
    echo "  FAIL: Xvfb did not become ready"
    cat "$TMP/xvfb.log"
    exit 1
fi
echo "GFX_SIGNAL_SERVER pid=$XVFB_PID"
if [ "${EIGS_SIGNAL_TEST_MOMENT:-}" = server ]; then while :; do sleep 1; done; fi

if ! ${CC:-cc} $WERROR_FLAGS -shared -fPIC -Wall -Wextra -Werror \
        "$ROOT/tests/gfx_locale_probe.c" -ldl -o "$TMP/locale-probe.so" \
   || [ ! -f "$TMP/locale-probe.so" ]; then
    # Without the probe every case would differ for a reason unrelated to
    # the locale; say so instead of reporting a confusing mismatch.
    echo "  FAIL: the locale preload probe did not build"
    exit 1
fi

run_case() {
    local locale=$1 gfx=$2 output=$3
    release=
    if [ "$gfx" = 1 ] && [ "${EIGS_SIGNAL_TEST_MOMENT:-}" = case ]; then
        release="$TMP/case-release"
    fi
    LC_ALL="$locale" LANG="$locale" EIGS_OPEN_GFX="$gfx" \
        EIGS_RELEASE_FILE="$release" \
        DISPLAY="$DISPLAY_NUM" SDL_VIDEODRIVER=x11 \
        "$ROOT/src/eigenscript" "$ROOT/tests/test_gfx_ctype_locale.eigs" >"$output" 2>&1 &
    PROGRAM_PID=$!
    if [ "$gfx" = 1 ]; then
        echo "GFX_SIGNAL_CASE pid=$PROGRAM_PID"
        if [ "${EIGS_SIGNAL_TEST_MOMENT:-}" = case ]; then while :; do sleep 1; done; fi
    fi
    wait "$PROGRAM_PID"
    result=$?
    PROGRAM_PID=
    return "$result"
}

run_case C 0 "$TMP/c-no-gfx"
run_case C 1 "$TMP/c-gfx"
LC_ALL=de_DE.ISO-8859-1 LANG=de_DE.ISO-8859-1 EIGS_OPEN_GFX=1 \
    EIGS_LOCALE_PROBE="$TMP/locale.log" LD_PRELOAD="$TMP/locale-probe.so" \
    DISPLAY="$DISPLAY_NUM" SDL_VIDEODRIVER=x11 \
    "$ROOT/src/eigenscript" "$ROOT/tests/test_gfx_ctype_locale.eigs" \
    >"$TMP/single-byte-gfx" 2>&1 &
PROGRAM_PID=$!
echo "GFX_SIGNAL_CASE pid=$PROGRAM_PID"
if [ "${EIGS_SIGNAL_TEST_MOMENT:-}" = case ]; then while :; do sleep 1; done; fi
wait "$PROGRAM_PID"
PROGRAM_PID=

if cmp -s "$TMP/c-no-gfx" "$TMP/c-gfx" && cmp -s "$TMP/c-no-gfx" "$TMP/single-byte-gfx"; then
    echo "  PASS: gfx leaves byte-oriented ctype answers replay-deterministic"
else
    echo "  FAIL: ctype builtin output depends on gfx or the environment locale"
    for f in c-no-gfx c-gfx single-byte-gfx; do
        echo "    $f:"; od -An -tx1c "$TMP/$f" | sed 's/^/      /'
    done
    exit 1
fi

# The preload probe records the successful setlocale return from the runtime
# process itself, after gfx causes SDL to load.
if grep -qx 'C.UTF-8 -> C.UTF-8' "$TMP/locale.log"; then
    echo "  PASS: LC_CTYPE after SDL loading is C.UTF-8"
else
    echo "  FAIL: LC_CTYPE after SDL loading is not C.UTF-8"
    cat "$TMP/locale.log" 2>/dev/null || true
    exit 1
fi
