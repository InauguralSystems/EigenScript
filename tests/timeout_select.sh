#!/usr/bin/env bash
# One selection point for the suite's GNU timeout wrapper (coreutils prefixes
# the executable with "g" on macOS).
eigs_timeout_select() {
    local seconds="$1"
    EIGS_TMO=""
    if command -v timeout >/dev/null 2>&1; then EIGS_TMO="timeout $seconds"
    elif command -v gtimeout >/dev/null 2>&1; then EIGS_TMO="gtimeout $seconds"; fi
}
