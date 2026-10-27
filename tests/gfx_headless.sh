#!/usr/bin/env bash
# Run a window-creating gfx test without ever inheriting the developer's
# display.  SDL's dummy driver is the standard SDL headless-test mechanism;
# unlike Xvfb it is available wherever the dynamically loaded SDL library is.

gfx_headless_run() {
    local seconds="$1" cap_kib="${EIGS_GFX_MEMORY_KIB:-2000000}" current
    shift

    command -v timeout >/dev/null 2>&1 || {
        echo "gfx-headless: GNU timeout is required" >&2
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

    (
        unset DISPLAY WAYLAND_DISPLAY
        export SDL_VIDEODRIVER=dummy
        current=$(ulimit -v) || exit 125
        if [ "$current" = unlimited ] || [ "$current" -gt "$cap_kib" ]; then
            ulimit -v "$cap_kib" || exit 125
        fi
        exec timeout "$seconds" "$@"
    )
}
