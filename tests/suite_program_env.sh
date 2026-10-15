#!/usr/bin/env bash
# One loader for per-program run conditions. tests/run_all_tests.sh,
# tools/jit_diff.sh, tools/replay_diff.sh and tools/phase2_corpus_diff.sh all
# source this file; tests/suite_program_env.txt is the policy, and nothing
# else spells a program's conditions (#1395; #1758's R1.1 critics found a
# corpus differential that ignored it and compared two early deaths).
#
# A row is a program's basename and its conditions: environment assignments,
# each one of SUITE_PROGRAM_FORMS. The forms are a whitelist: any other word
# is refused by name, never passed through. The suite runs every corpus
# program from src/ with stdin /dev/null and no arguments, so a row has no
# argument, stdin or working-directory field; a program that needs one (a
# generator fed by its child script, a fixture of another host) does not run
# standalone, and the corpus differential's ledger declares it
# (tests/phase2/corpus_nonzero.txt).

SUITE_PROGRAM_FORMS=" EIGS_STRICT=0 SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy "

# suite_program_env NAME: print NAME's row (its conditions, possibly empty).
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

# suite_program_check NAME: print NAME's conditions after checking every word
# against SUITE_PROGRAM_FORMS; rc 2, with the reason on stderr, for a
# duplicate row or a word outside the forms.
suite_program_check() {
    local name="$1" setting w
    setting=$(suite_program_env "$name") || {
        echo "suite-program-env: invalid duplicate entry for ${name##*/}" >&2
        return 2
    }
    for w in $setting; do
        case "$SUITE_PROGRAM_FORMS" in
            *" $w "*) ;;
            *) echo "suite-program-env: unsupported condition for ${name##*/}: $w" >&2; return 2 ;;
        esac
    done
    printf '%s\n' "$setting"
}

# suite_program_run NAME CMD...: run CMD (a command or a shell function)
# under NAME's conditions, as prefix assignments, so they reach CMD's
# children. Every word was checked against the whitelist before the eval.
suite_program_run() {
    local name="$1" setting
    shift
    setting=$(suite_program_check "$name") || return 2
    if [ -z "$setting" ]; then
        "$@"
        return
    fi
    eval "$setting"' "$@"'
}
