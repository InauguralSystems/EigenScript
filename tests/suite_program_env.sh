#!/usr/bin/env bash
# One lookup for per-program suite environment.  Both run_all_tests.sh and
# tools/jit_diff.sh source this file; suite_program_env.txt is the policy.

suite_program_env() {
    local name="${1##*/}" file="${EIGS_TEST_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/suite_program_env.txt"
    awk -v name="$name" '
        $0 !~ /^[[:space:]]*#/ && NF && $1 == name {
            hits++
            for (i = 2; i <= NF; i++) printf "%s%s", (i == 2 ? "" : " "), $i
            printf "\n"
        }
        END { if (hits > 1) exit 2 }
    ' "$file"
}

suite_program_run() {
    local name="$1" setting
    shift
    setting=$(suite_program_env "$name") || {
        echo "suite-program-env: invalid duplicate entry for ${name##*/}" >&2
        return 2
    }
    case "$setting" in
        "") "$@" ;;
        EIGS_STRICT=0) EIGS_STRICT=0 "$@" ;;
        *) echo "suite-program-env: unsupported environment for ${name##*/}: $setting" >&2; return 2 ;;
    esac
}
