#!/usr/bin/env bash
# Test-only dependencies shared by the dev/CI image, native macOS CI, and the
# release artifact suite. Keep package policy here so those environments cannot
# acquire different answers. Builds install their link-time dependencies first.
set -euo pipefail

case "${1:-}" in
    linux)
        apt-get update
        apt-get install -y --no-install-recommends \
            libsdl2-dev libsdl2-mixer-2.0-0 xvfb xauth x11-utils xdotool \
            python3-pil zlib1g-dev
        ;;
    macos)
        runner="${2:-}"
        case "$runner" in
            macos-15-intel) formula=llvm@18 ;;
            macos-latest) formula=llvm@22; brew install --force-bottle "$formula" ;;
            *) echo "unsupported macOS runner: $runner" >&2; exit 2 ;;
        esac
        # coreutils supplies timeout (or gtimeout), required by the gfx example
        # and sanitizer controls. Removing this provision makes the release
        # dry-run fail on macOS rather than deferring discovery to a tag cut.
        if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
            brew install --force-bottle coreutils
        fi
        brewbin="$(brew --prefix "$formula")/bin"
        test -x "$brewbin/clang"
        echo "PATH=$brewbin:$PATH" >> "$GITHUB_ENV"
        echo "EIGS_ASAN_GFX_CC=clang" >> "$GITHUB_ENV"
        ;;
    *) echo "usage: $0 linux | macos <macos-latest|macos-15-intel>" >&2; exit 2 ;;
esac
