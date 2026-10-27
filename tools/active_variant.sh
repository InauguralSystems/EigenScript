#!/bin/sh
# Print the build variant to which src/eigenscript is hard-linked.
# `test -ef` is specified by POSIX and works with both GNU and BSD userlands.
# --goal prints the make GOAL that rebuilds that variant and re-points
# src/eigenscript instead: release's goal is `build` (there is no `release`
# target); every other variant's goal is its name.  One mapping for the
# suite's freshness rebuild and the stop gate.
goal=0
if [ "${1:-}" = --goal ]; then goal=1; shift; fi
ROOT=${1:-"$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"}
bin=$ROOT/src/eigenscript

[ -f "$bin" ] || exit 1

variant=
for cand in "$ROOT"/build/*/eigenscript; do
    [ -f "$cand" ] || continue
    [ "$bin" -ef "$cand" ] || continue
    if [ -n "$variant" ]; then
        exit 2
    fi
    variant=${cand%/eigenscript}
    variant=${variant##*/}
done

[ -n "$variant" ] || exit 1
[ "$goal" = 1 ] && [ "$variant" = release ] && variant=build
printf '%s\n' "$variant"
