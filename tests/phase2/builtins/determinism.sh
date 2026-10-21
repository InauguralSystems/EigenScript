#!/usr/bin/env bash
# determinism.sh [case...]: record the cases three times (twice normally, then
# pinned to core 0 at nice 19) and compare every .pre and .tag across the
# three runs. A value the OS or the environment chooses (a port, a pid, a
# time, a path) shows up here as UNSTABLE (ruling R1.6a-D2). The records left
# in builtins/ are the third run's. PRE_BIN, TAG_BIN and the PRE_BIN_<P> /
# TAG_BIN_<P> profile binaries pass through to run_probes.sh.
# Exit 1 on any unstable record, 2 on an instrument failure.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/r16det.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
for r in 1 2 3; do
    pin=(); [ "$r" -eq 3 ] && pin=(taskset -c 0 nice -n 19)
    if ! "${pin[@]}" bash "$HERE/run_probes.sh" "$@" > "$WORK/run$r.log" 2>&1; then
        echo "FAIL: recording $r: $(tail -3 "$WORK/run$r.log" | tr '\n' ' ')"; exit 2
    fi
    echo "run $r: $(tail -1 "$WORK/run$r.log")"
    mkdir "$WORK/R$r" && cp "$HERE"/builtins/*.pre "$HERE"/builtins/*.tag "$WORK/R$r/" || exit 2
done
n=0; unstable=0
for f in "$WORK"/R1/*; do
    b=$(basename "$f"); n=$((n + 1))
    if ! cmp -s "$f" "$WORK/R2/$b" || ! cmp -s "$f" "$WORK/R3/$b"; then unstable=$((unstable + 1)); echo "UNSTABLE $b"; fi
done
want=$(( $(ls "$HERE"/builtins/*.pre | wc -l) * 2 ))
echo "compared=$n records=$want unstable=$unstable"
[ "$n" -eq "$want" ] && [ "$n" -gt 0 ] && [ "$unstable" -eq 0 ] || exit 1
