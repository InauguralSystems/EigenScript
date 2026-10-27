#!/bin/bash
# Deterministic perf regression gate (#398). Wall-clock medians flake on shared
# CI runners, so the GATE uses cachegrind instruction counts (Ir) instead:
# same binary + same input in one environment gives a diffable instruction
# count. glibc ifunc selection can change the count across hosts (#1939).
# Fails if any
# workload's Ir exceeds its checked-in baseline by more than THRESHOLD_PCT.
#
#   bench/check_regression.sh            # gate: compare vs bench/baseline.txt
#   bench/check_regression.sh --update   # regenerate the baseline
#   bench/check_regression.sh --selftest # prove a 2x-work pessimization is caught
#   bench/check_regression.sh --list-vs  # derived --vs workload/tier population
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="${EIGENSCRIPT:-$DIR/../src/eigenscript}"
BASELINE="${BASELINE_OVERRIDE:-$DIR/baseline.txt}"
THRESHOLD_PCT=5

# Drop caller EIGS_* settings, then select the requested tier explicitly.
# --vs measures the union of bench/*.eigs (default JIT) and every declared
# workload/tier pair, so its own CI log can re-declare every max_ci (#1939).
ir_of() {  # ir_of <binary> <file> [jit|off] -> instruction count
    local tier="${3:-jit}" tier_env=
    case "$tier" in jit) ;; off) tier_env=EIGS_JIT_OFF=1 ;; *) return 2 ;; esac
    env $(compgen -e | grep '^EIGS_' | sed 's/^/-u /') $tier_env \
        valgrind --tool=cachegrind --cachegrind-out-file=/dev/null "$1" "$2" 2>&1 \
        | grep -oE "I *refs:[ ]*[0-9,]+" | grep -oE "[0-9,]+" | tr -d ','
}

case "${1:-}" in
--update)
    : > "$BASELINE"
    for f in "$DIR"/*.eigs; do echo "$(basename "$f" .eigs) $(ir_of "$EIGS" "$f")" >> "$BASELINE"; done
    echo "baseline updated:"; cat "$BASELINE"; exit 0 ;;
--selftest)
    base=$(ir_of "$EIGS" "$DIR/scalar_loop.eigs")
    tmp=$(mktemp --suffix=.eigs)
    # ~2x the iterations of scalar_loop => ~2x instructions, well over threshold.
    printf 'total is 0\nfor i in range of 80000:\n    total is total + (i * 2) - 1\nprint of total\n' > "$tmp"
    doubled=$(ir_of "$EIGS" "$tmp"); rm -f "$tmp"
    inc=$(( (doubled - base) * 100 / base ))
    if [ "$inc" -gt "$THRESHOLD_PCT" ]; then
        echo "SELFTEST OK: a 2x-work pessimization is flagged (+${inc}% Ir > ${THRESHOLD_PCT}%)"
    else
        echo "SELFTEST FAILED: 2x pessimization not flagged (+${inc}%) — gate is vacuous"; exit 1
    fi
    # Second plant, the stale direction: a baseline 2x ABOVE the real count
    # must make the default gate fail, not print ok (the decay the two-sided
    # check exists to stop).
    fake=$(mktemp); echo "scalar_loop $(( base * 2 ))" > "$fake"
    if BASELINE_OVERRIDE="$fake" "$0" >/dev/null 2>&1; then
        rm -f "$fake"; echo "SELFTEST FAILED: a 2x-stale baseline passed the gate — decay is invisible"; exit 1
    fi
    rm -f "$fake"; echo "SELFTEST OK: a 2x-stale baseline is flagged"; exit 0 ;;
--vs|--list-vs)
    # Base and candidate use this gate's own measurement recipe. Its CI
    # counts, including off-tier declarations, are the source of max_ci.
    ref="${2:-}"; fail=0; used=0
    if [ "$1" = --vs ] && [ -z "$ref" ]; then echo "  FAIL: --vs requires a reference binary"; exit 2; fi
    decl=$(bash "$DIR/../tools/phase2_cost.sh" --declared all --method ci) \
        || { echo "  FAIL: cannot read the declared costs (tools/phase2_cost.sh --declared all --method ci)"; exit 2; }
    ndecl=$(awk 'NF {n++} END {print n+0}' <<< "$decl")
    work=$(mktemp -d "${TMPDIR:-/tmp}/eigs-bench-vs.XXXXXX") || exit 2
    trap 'rm -rf "$work"' EXIT
    for f in "$DIR"/*.eigs; do
        printf 'bench/%s\tjit\n' "$(basename "$f")" >> "$work/population.unsorted"
    done
    awk -F'\t' 'NF {print $1 "\t" $2}' <<< "$decl" >> "$work/population.unsorted"
    LC_ALL=C sort -u "$work/population.unsorted" > "$work/population"
    if [ "$1" = --list-vs ]; then cat "$work/population"; exit 0; fi
    nrows=$(wc -l < "$work/population")
    echo "  tiers: explicit jit/off (caller EIGS_* unset); column: max_ci; stale_below_max=0.5; declared rows: $ndecl; measured rows: $nrows"
    while IFS=$'\t' read -r workload tier; do
        f="$DIR/../$workload"
        [ -f "$f" ] || { echo "  FAIL: missing workload: $workload"; exit 2; }
        a=$(ir_of "$EIGS" "$f" "$tier")
        b=$(ir_of "$ref" "$f" "$tier")
        [[ "$a" =~ ^[1-9][0-9]*$ && "$b" =~ ^[1-9][0-9]*$ ]] \
            || { echo "  FAIL: $workload $tier: no instruction count (cand='$a' ref='$b')"; exit 2; }
        row=$(awk -F'\t' -v w="$workload" -v t="$tier" '$1 == w && $2 == t' <<< "$decl")
        if [ -n "$row" ]; then used=$((used + 1)); fi
        # One exact two-sided predicate; selects max_ci for both tiers.
        python3 "$DIR/../tools/phase2_cost_declarations.py" --method ci \
            --row "$workload" "$tier" "$b" "$a"
        rc=$?
        [ "$rc" -le 1 ] || exit "$rc"
        [ "$rc" -eq 0 ] || fail=1
    done < "$work/population"
    # Every declaration was measured exactly once, regardless of workload dir
    # or tier. The union's population is derived, never hand-maintained.
    [ "$used" -eq "$ndecl" ] || { echo "  FAIL: declared rows=$ndecl applied=$used"; exit 2; }
    [ "$fail" -eq 0 ] && echo "no instruction-count regressions vs reference (threshold ${THRESHOLD_PCT}%; declared rows applied=$used; measured rows=$nrows)"
    exit $fail ;;

esac

# Default (local): compare against the checked-in baseline. NOTE the baseline is
# environment-specific (whoever ran --update); for a cross-environment gate use
# --vs against a same-env reference build, which is what CI does.
#
# TWO-SIDED. A one-sided "more than +5% fails" check against a checked-in
# number decays silently: every improvement that lands without --update
# widens the gap, and the gate keeps printing ok while measuring less.
# Measured 2026-09-20: the baseline sat 6-36% ABOVE main on every workload,
# so a +30% regression on scalar_loop would have passed locally. An
# improvement past the threshold is therefore also a failure — "baseline is
# stale, run --update" — so the checked-in number cannot drift out from
# under the gate. --vs (CI) is unaffected: it diffs two same-env builds.
[ -f "$BASELINE" ] || { echo "no baseline — run: $0 --update"; exit 1; }
fail=0; stale=0
while read -r name base; do
    f="$DIR/$name.eigs"; [ -f "$f" ] || continue
    cur=$(ir_of "$EIGS" "$f")
    inc=$(( (cur - base) * 100 / base ))
    if [ $(( (cur - base) * 100 )) -gt $(( THRESHOLD_PCT * base )) ]; then
        echo "  REGRESSION: $name  Ir ${base} -> ${cur}  (+${inc}% > ${THRESHOLD_PCT}%)"; fail=1
    elif [ $(( (cur - base) * 100 )) -lt $(( -THRESHOLD_PCT * base )) ]; then
        echo "  STALE BASELINE: $name  Ir ${base} -> ${cur}  (${inc}%, gate would be measuring less)"; stale=1
    else
        echo "  ok: $name  Ir ${cur}  (${inc}% vs baseline)"
    fi
done < "$BASELINE"
if [ "$stale" -eq 1 ]; then
    echo "baseline is stale by more than ${THRESHOLD_PCT}% on at least one workload — run: $0 --update (and commit bench/baseline.txt)"
    fail=1
fi
[ "$fail" -eq 0 ] && echo "no instruction-count regressions (threshold ${THRESHOLD_PCT}%, two-sided)"
exit $fail
