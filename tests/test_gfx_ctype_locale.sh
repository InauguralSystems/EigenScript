#!/bin/bash
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# Helper C is compiled with the repo's mandatory flags, as the other C-building
# tests do; CI's compiler guard rejects a compile without them.
WERROR_FLAGS_FILE="$ROOT/tools/werror_flags.txt"
. "$ROOT/tools/read_werror_flags.sh" || exit 1
DISPLAY_NUM=":$((190 + ($$ % 700)))"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs-1681-ctype.XXXXXX")
cleanup() {
    [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null || true
    [ -n "${XVFB_PID:-}" ] && wait "$XVFB_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM

Xvfb "$DISPLAY_NUM" -screen 0 640x480x24 >"$TMP/xvfb.log" 2>&1 &
XVFB_PID=$!
for _ in $(seq 1 100); do
    xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1 && break
    kill -0 "$XVFB_PID" 2>/dev/null || break
    sleep 0.1
done
if ! xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1; then
    echo "  FAIL: Xvfb did not become ready"
    cat "$TMP/xvfb.log"
    exit 1
fi

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
    LC_ALL="$locale" LANG="$locale" EIGS_OPEN_GFX="$gfx" \
        DISPLAY="$DISPLAY_NUM" SDL_VIDEODRIVER=x11 \
        "$ROOT/src/eigenscript" "$ROOT/tests/test_gfx_ctype_locale.eigs" >"$output" 2>&1
}

run_case C 0 "$TMP/c-no-gfx"
run_case C 1 "$TMP/c-gfx"
LC_ALL=de_DE.ISO-8859-1 LANG=de_DE.ISO-8859-1 EIGS_OPEN_GFX=1 \
    EIGS_LOCALE_PROBE="$TMP/locale.log" LD_PRELOAD="$TMP/locale-probe.so" \
    DISPLAY="$DISPLAY_NUM" SDL_VIDEODRIVER=x11 \
    "$ROOT/src/eigenscript" "$ROOT/tests/test_gfx_ctype_locale.eigs" \
    >"$TMP/single-byte-gfx" 2>&1

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
