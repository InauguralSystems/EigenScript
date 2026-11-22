#!/usr/bin/env bash
# Run a window-creating gfx test without ever inheriting the developer's
# display.  SDL's dummy driver is the standard SDL headless-test mechanism;
# unlike Xvfb it is available wherever the dynamically loaded SDL library is.

_gfx_headless_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -F gfx_address_space_apply >/dev/null 2>&1; then
    . "$_gfx_headless_here/../tools/gfx_address_space.sh" || return 1
fi

gfx_headless_run() {
    local seconds="$1" cap_kib="${EIGS_GFX_MEMORY_KIB:-1500000}" timeout_cmd binary instrumentation platform arg i
    local argv=("$@")
    shift

    timeout_cmd=${EIGS_TMO%% *}
    [ -n "$timeout_cmd" ] && command -v "$timeout_cmd" >/dev/null 2>&1 || {
        echo "gfx-headless: suite timeout command is unavailable" >&2
        return 125
    }
    [[ "$seconds" =~ ^[1-9][0-9]*$ ]] || {
        echo "gfx-headless: invalid timeout: $seconds" >&2
        return 125
    }
    [[ "$cap_kib" =~ ^[1-9][0-9]*$ ]] || {
        echo "gfx-headless: invalid memory cap: $cap_kib" >&2
        return 125
    }

    binary="$1"
    if [ "$binary" = env ]; then
        i=2
        while [ "$i" -le "$#" ]; do
            arg=${argv[$i]}
            case "$arg" in
                -u|--unset) i=$((i + 2)) ;;
                *=*) i=$((i + 1)) ;;
                *) binary="$arg"; break ;;
            esac
        done
    fi
    case "$binary" in */*) ;; *) binary=$(command -v "$binary") || return 125 ;; esac
    instrumentation=$(gfx_binary_instrumentation "$binary") || return 125
    platform=$(uname -s) || return 125

    (
        export SDL_VIDEODRIVER=dummy
        gfx_address_space_apply "$binary" "$instrumentation" "$platform" "$cap_kib" || exit 125
        # Unsetting a function's temporary DISPLAY assignment can expose the
        # caller's exported value. Remove it at the child process boundary.
        exec env -u DISPLAY -u WAYLAND_DISPLAY "$timeout_cmd" "$seconds" "$@"
    )
}
