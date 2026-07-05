#!/bin/bash
# Wall-clock n=5 medians per bench workload (#398) — the house rule for perf
# numbers. These feed docs/PERFORMANCE.md and are environment-dependent (a dev
# box or a CI runner under load will differ). The non-flaky REGRESSION GATE is
# a separate, deterministic metric: bench/check_regression.sh (cachegrind
# instruction counts). Workloads with nondeterministic input would be pinned
# under EIGS_TRACE for input-determinism; these are pure-compute, so none is.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="${EIGENSCRIPT:-$DIR/../src/eigenscript}"

median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }

printf "%-20s %10s\n" "workload" "median_ms"
printf "%-20s %10s\n" "--------" "---------"
for f in "$DIR"/*.eigs; do
    name=$(basename "$f" .eigs)
    times=()
    for r in 1 2 3 4 5; do
        t0=$(date +%s%N)
        "$EIGS" "$f" >/dev/null 2>&1
        t1=$(date +%s%N)
        times+=( $(( (t1 - t0) / 1000000 )) )
    done
    printf "%-20s %10s\n" "$name" "$(median "${times[@]}")"
done
