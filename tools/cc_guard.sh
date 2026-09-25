#!/usr/bin/env bash
# Compiler boundary for CI: check actual C compiler argv, then delegate.
set -eu
if [[ ${1:-} == --report ]]; then
    log=${CC_GUARD_LOG:?CC_GUARD_LOG is required}
    count=$(wc -l < "$log") || exit 1
    (( count > 0 )) || { echo 'cc-guard: examined=0' >&2; exit 1; }
    echo "cc-guard: examined=$count"
    exit 0
fi
name=${0##*/}
case "$name" in gcc|cc|clang|emcc) ;; *) echo "cc-guard: unknown compiler $name" >&2; exit 1;; esac
compile=0 skip=0 want_x=0
switch=0 comment=0 indent=0
for arg do
    if (( want_x )); then
        [[ $arg == c ]] && compile=1
        want_x=0
    fi
    case "$arg" in
        -c|*.c|-xc) compile=1 ;;
        -x) want_x=1 ;;
        -E|-M|-MM|--version|-dumpversion|-dumpfullversion|-print-*) skip=1 ;;
        -Werror=switch) switch=1 ;;
        -Werror=comment) comment=1 ;;
        -Werror=misleading-indentation) indent=1 ;;
    esac
done
if (( compile && !skip )); then
    log=${CC_GUARD_LOG:?CC_GUARD_LOG is required for C compiles}
    printf 'compile\n' >> "$log"
    for pair in "-Werror=switch:$switch" "-Werror=comment:$comment" "-Werror=misleading-indentation:$indent"; do
        if [[ ${pair##*:} == 0 ]]; then
            printf 'cc-guard: compile without %s:' "${pair%:*}" >&2
            printf ' %q' "$@" >&2
            printf '\n' >&2
            exit 1
        fi
    done
fi
# Resolve the first executable beyond our links. -ef also rejects aliases of self.
IFS=: read -r -a dirs <<< "$PATH:"
for dir in "${dirs[@]}"; do
    candidate=${dir:-.}/$name
    if [[ -x $candidate && ! $candidate -ef $0 ]]; then exec "$candidate" "$@"; fi
done
echo "cc-guard: real compiler $name not found beyond guard" >&2
exit 1
