#!/bin/bash
# #915 observer-elision measurement harness, per the perf-attribution discipline.
#
#   * ONE byte-identical binary serves both arms. The baseline arm is
#     EIGS_OBS_FORCE=1 (the gate's own escape hatch), so a second build cannot
#     confound the comparison.
#   * Arms are INTERLEAVED (A B A B ...), not blocked, so thermal or load drift
#     across the run cannot be read as an effect.
#   * n=5 per arm, medians reported.
#   * The solver's own final counters are compared across every run. If the
#     search changed, the timing is not a measurement of the same work.
#
# THE COUNTER CHECK MUST NOT BE ABLE TO PASS VACUOUSLY. The first version of
# this harness extracted counters with a pattern of the form
# `status=[A-Z]* conflicts=...` — but the real line reads
# `status=UNSAT elapsed_s=299.99 conflicts=9986 ...`, so the pattern matched
# NOTHING. The extracted string was empty on every run, the "have I seen
# counters yet" guard therefore stayed armed forever, and the two arms were
# never once compared. It printed
#
#     counters (identical across all 10 runs):
#
# with an empty value, which reads as a passed check.
#
# There were TWO independent causes, and fixing only the visible one leaves the
# check just as vacuous. The second: run_one was invoked as `a=$(run_one base)`,
# so every assignment to COUNTERS/HAVE_COUNTERS happened in a COMMAND-
# SUBSTITUTION SUBSHELL and was discarded on return. The parent's "have I seen
# counters yet" flag could never leave 0. Timings survived only because they
# were the substitution's stdout.
#
# So: run_one writes its full output to a FILE, and the parent — not a subshell
# — does the extracting and comparing. The extraction is anchored on the whole
# DONE line with only elapsed_s removed (elapsed_s is the thing that is SUPPOSED
# to differ), and an EMPTY extraction is a VOID result rather than a match.
#
# Usage: tools/observer_gate_measure.sh
#   ROWS/COLS  Tseitin torus size (default 4x4 — the #915 workload)
#   N          runs per arm (default 5)
#   EMS        path to the EigenMiniSat checkout
set -u
ROWS="${ROWS:-4}"; COLS="${COLS:-4}"; N="${N:-5}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${BIN:-$REPO/src/eigenscript}"
EMS="${EMS:-$REPO/../EigenMiniSat}"
cd "$EMS" || { echo "FAIL: no EigenMiniSat checkout at $EMS"; exit 2; }

declare -a A=() B=()
COUNTERS=""; HAVE_COUNTERS=0; VOID=0; LAST_T=""

counters_of() {   # strip only elapsed_s; everything else must match
    printf '%s\n' "$1" | grep '^DONE' | sed -E 's/ elapsed_s=[0-9.]+//' | head -1
}

OUTF=$(mktemp); trap 'rm -f "$OUTF"' EXIT

# Runs one arm into $OUTF. Deliberately NOT called in a command substitution —
# see the header: the state it updates must survive into the parent shell.
run_one() {
    if [ "$1" = base ]; then
        { /usr/bin/time -f '%e' env EIGS_OBS_FORCE=1 "$BIN" benchmarks/tseitin_ladder.eigs "$ROWS" "$COLS" 999; } > "$OUTF" 2>&1
    else
        { /usr/bin/time -f '%e' "$BIN" benchmarks/tseitin_ladder.eigs "$ROWS" "$COLS" 999; } > "$OUTF" 2>&1
    fi
    LAST_T=$(tail -1 "$OUTF")
    local c; c=$(counters_of "$(cat "$OUTF")")
    if [ -z "$c" ]; then
        echo "VOID: no DONE line in a $1 run — the harness measured nothing"
        VOID=1
    elif [ "$HAVE_COUNTERS" -eq 0 ]; then
        COUNTERS="$c"; HAVE_COUNTERS=1
    elif [ "$c" != "$COUNTERS" ]; then
        echo "VOID: counters differ across runs"; echo "  first: $COUNTERS"; echo "  this : $c"
        VOID=1
    fi
}

echo "workload: tseitin torus ${ROWS}x${COLS}-odd, n=$N per arm, interleaved, one binary"
for i in $(seq 1 "$N"); do
    run_one base;  A+=("$LAST_T"); printf '  round %d  base  %8s s\n' "$i" "$LAST_T"
    run_one gated; B+=("$LAST_T"); printf '  round %d  gated %8s s\n' "$i" "$LAST_T"
done

med() { printf '%s\n' "$@" | sort -g | awk '{v[NR]=$1} END{print (NR%2)?v[(NR+1)/2]:(v[NR/2]+v[NR/2+1])/2}'; }
MA=$(med "${A[@]}"); MB=$(med "${B[@]}")
echo
printf 'base  median: %s s   (%s)\n' "$MA" "${A[*]}"
printf 'gated median: %s s   (%s)\n' "$MB" "${B[*]}"
awk -v a="$MA" -v b="$MB" 'BEGIN{ if (b>0) printf "speedup: %.2fx\n", a/b }'

# Print the counters that were actually compared — an empty line here is the
# tell that the check above was vacuous, so it is never allowed to be empty.
if [ "$HAVE_COUNTERS" -eq 0 ]; then
    echo "RESULT: VOID — no counters were ever extracted; the equality check ran on nothing"
    exit 1
fi
echo "counters, identical across all $((2 * N)) runs:"
echo "  $COUNTERS"
[ "$VOID" -ne 0 ] && { echo "RESULT: VOID — the two arms did not do the same work"; exit 1; }
echo "RESULT: valid — same search, same binary, interleaved"
