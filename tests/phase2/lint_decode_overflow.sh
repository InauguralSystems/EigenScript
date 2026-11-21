#!/usr/bin/env bash
# N14: manifest JSON overflow must not produce a successful lint verdict.
set -eu
bin=$1
case "$bin" in /*) ;; *) bin="$PWD/$bin" ;; esac
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
. "$root/tests/lsan_classify.sh"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/eigs-r25-lint.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"
printf 'print of 1\n' > p.eigs
cases=0
for strict in 0 1; do
    for mode in plain json; do
        for kind in overflow finite malformed; do
            case "$kind" in
                overflow) printf '{"other":1e400}\n' > eigs.json ;;
                finite) printf '{"other":1e308}\n' > eigs.json ;;
                # Existing non-latching parse-flag failures remain lenient.
                malformed) printf '{broken}\n' > eigs.json ;;
            esac
            if [ "$mode" = json ]; then set -- --json; else set --; fi
            rc=0
            EIGS_STRICT="$strict" "$bin" --lint "$@" p.eigs > out 2> err || rc=$?
            combined=$(cat out err)
            class=0
            lsan_classify "$combined" || class=$?
            if [ "$class" -ne 2 ]; then
                printf '%s\n' "$combined" >&2
                echo "lint-decode-overflow: sanitizer output strict=$strict mode=$mode kind=$kind" >&2
                exit 1
            fi
            if [ "$kind" = overflow ]; then
                if [ "$rc" -ne 1 ] ||
                   ! grep -q 'JSON number is outside the finite float range' err ||
                   grep -q 'no issues found' out err || [ "$(cat out)" = '[]' ]; then
                    printf '%s\n' "$combined" >&2
                    echo "lint-decode-overflow: refused verdict missing strict=$strict mode=$mode rc=$rc" >&2
                    exit 1
                fi
            elif [ "$rc" -ne 0 ] ||
                 { [ "$mode" = json ] && [ "$(cat out)" != '[]' ]; } ||
                 { [ "$mode" = plain ] && ! grep -q 'no issues found' err; }; then
                printf '%s\n' "$combined" >&2
                echo "lint-decode-overflow: $kind control changed strict=$strict mode=$mode rc=$rc" >&2
                exit 1
            fi
            cases=$((cases + 1))
        done
    done
done
printf 'lint-decode-overflow: cases=%d; overflow refuses; finite and malformed controls preserved\n' "$cases"
