#!/usr/bin/env bash
# Shared address-space policy for commands which may initialize SDL video.
# ASan owns a multi-terabyte shadow mapping, so an instrumented executable
# must inherit an unlimited address space. Ordinary Linux children receive the
# runaway cap; Darwin children inherit their parent's limits.

gfx_asan_symbols() {
    printf '%s\n' "$1" | awk '$NF ~ /^_?__asan_init(@.*)?$/ { found=1 } END { exit !found }'
}

gfx_binary_instrumentation() {
    local symbols
    # Contract tests and small harnesses may use an executable script. Scripts
    # cannot contain an ASan runtime; the interpreter is outside this policy.
    if [ "$(dd if="$1" bs=2 count=1 2>/dev/null)" = '#!' ]; then
        echo ordinary
        return 0
    fi
    if symbols=$(readelf --wide --syms "$1" 2>/dev/null) ||
       symbols=$(nm "$1" 2>/dev/null); then
        if gfx_asan_symbols "$symbols"; then echo asan; else echo ordinary; fi
    else
        echo "FAIL: cannot inspect GFX executable instrumentation: $1" >&2
        return 1
    fi
}

gfx_address_space_apply() { # executable, instrumentation, platform, cap KiB
    local executable="$1" instrumentation="$2" platform="$3" cap_kib="${4:-1500000}"
    case "$platform" in Linux|Darwin) ;; *)
        echo 'FAIL: unsupported GFX address-space platform' >&2; return 125 ;;
    esac
    case "$instrumentation" in
        ordinary)
            [ "$platform" != Linux ] || ulimit -v "$cap_kib" || return 125 ;;
        asan)
            [ "$(ulimit -v)" = unlimited ] || {
                echo "FAIL: instrumented GFX requires an uncapped parent virtual address space: $executable" >&2
                return 125
            } ;;
        *) echo 'FAIL: unknown GFX executable instrumentation' >&2; return 125 ;;
    esac
}
