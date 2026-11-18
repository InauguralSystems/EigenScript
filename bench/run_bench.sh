#!/bin/bash
# Diagnostic wall-clock samples per bench workload (#398). Each row reports the
# median and its min..max sample spread in microseconds; these environment-
# dependent measurements are not published performance figures. A sample runs from
# one clock_us call to the next, and each call starts a perl process: a sample
# is therefore never shorter than its workload's run, and is longer by the time
# that process takes to start and to read the clock. The non-flaky REGRESSION GATE is
# a separate, deterministic metric: bench/check_regression.sh (cachegrind
# instruction counts). Workloads with nondeterministic input would be pinned
# under EIGS_TRACE for input-determinism; these are pure-compute, so none is.
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="${EIGENSCRIPT:-$DIR/../src/eigenscript}"

median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }
clock_us() { perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000000'; }

printf "%-20s %12s %12s %12s\n" "workload" "median_us" "min_us" "max_us"
printf "%-20s %12s %12s %12s\n" "--------" "---------" "------" "------"
for f in "$DIR"/*.eigs; do
    name=$(basename "$f" .eigs)
    times=()
    for r in 1 2 3 4 5; do
        t0=$(clock_us)
        "$EIGS" "$f" >/dev/null 2>&1
        rc=$?
        t1=$(clock_us)
        if [ "$rc" -ne 0 ]; then
            printf 'ERROR: workload %s failed on timed invocation %s (exit %s)\n' "$name" "$r" "$rc" >&2
            exit "$rc"
        fi
        times+=( $((t1 - t0)) )
    done
    spread=$(printf '%s\n' "${times[@]}" | sort -n)
    min=$(printf '%s\n' "$spread" | sed -n '1p')
    max=$(printf '%s\n' "$spread" | sed -n '$p')
    printf "%-20s %12s %12s %12s\n" "$name" "$(median "${times[@]}")" "$min" "$max"
done
