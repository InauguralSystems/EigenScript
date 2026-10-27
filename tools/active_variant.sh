#!/bin/sh
# Print the build variant to which src/eigenscript is hard-linked.
# `test -ef` is specified by POSIX and works with both GNU and BSD userlands.
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
printf '%s\n' "$variant"
