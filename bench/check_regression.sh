#!/bin/bash
# Deterministic perf regression gate (#398). Wall-clock medians flake on shared
# CI runners, so the GATE uses cachegrind instruction counts (Ir) instead:
# same binary + same input => identical Ir, run to run, machine to machine. A
# regression is then a diffable fact, not a statistical argument. Fails if any
# workload's Ir exceeds its checked-in baseline by more than THRESHOLD_PCT.
#
#   bench/check_regression.sh            # gate: compare vs bench/baseline.txt
#   bench/check_regression.sh --update   # regenerate the baseline
#   bench/check_regression.sh --selftest # prove a 2x-work pessimization is caught
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="${EIGENSCRIPT:-$DIR/../src/eigenscript}"
BASELINE="${BASELINE_OVERRIDE:-$DIR/baseline.txt}"
THRESHOLD_PCT=5

# The run line fixes the VM tier: every EIGS_* variable is dropped (as
# tools/phase2_cost.sh does), so EIGS_JIT_OFF is unset and every workload runs
# in the DEFAULT tier, the JIT. Its declared costs are therefore the `jit` rows.
ir_of() {  # ir_of <binary> <file> -> instruction count
    env $(compgen -e | grep '^EIGS_' | sed 's/^/-u /') \
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
--vs)
    # Compare THIS binary ($EIGENSCRIPT) against a reference binary ($2) on the
    # same workloads. Both built in the same environment => the Ir difference is
    # a pure code-change signal (this is what CI runs: PR binary vs origin/main
    # binary, so no cross-machine baseline drift). Fails on > THRESHOLD_PCT.
    # A workload with a DECLARED temporary cost (#1758: the `jit` rows of
    # tests/phase2/cost_expect.txt, read through their one parser) is bounded
    # by its declared max instead, and prints the round that recovers it.
    ref="$2"; fail=0; used=0
    decl=$(bash "$DIR/../tools/phase2_cost.sh" --declared jit) \
        || { echo "  FAIL: cannot read the declared costs (tools/phase2_cost.sh --declared jit)"; exit 2; }
    ndecl=$(awk -F'\t' 'index($1, "bench/") == 1' <<< "$decl" | wc -l)
    echo "  tier: jit (EIGS_* unset on every run line); declared bench rows: $ndecl"
    for f in "$DIR"/*.eigs; do
        name=$(basename "$f" .eigs)
        a=$(ir_of "$EIGS" "$f")
        b=$(ir_of "$ref" "$f")
        [[ "$a" =~ ^[1-9][0-9]*$ && "$b" =~ ^[1-9][0-9]*$ ]] \
            || { echo "  FAIL: $name: no instruction count (cand='$a' ref='$b')"; exit 2; }
        inc=$(( (a - b) * 100 / b ))
        row=$(awk -F'\t' -v w="bench/$name.eigs" '$1 == w' <<< "$decl")
        if [ -n "$row" ]; then
            IFS=$'\t' read -r _ max round <<< "$row"; used=$((used + 1))
            # Exact decimal compare, the predicate tools/phase2_cost.sh uses.
            if python3 -c 'import sys; from decimal import Decimal as D; a, b, m = map(D, sys.argv[1:]); sys.exit((a - b) * 100 > m * b)' "$a" "$b" "$max"; then
                echo "  DECLARED: $name  Ir ${b} -> ${a}  (+${inc}% <= declared +${max}%, recover_round=${round})"
            else
                echo "  REGRESSION: $name  Ir ${b} -> ${a}  (+${inc}% > declared +${max}%, recover_round=${round})"; fail=1
            fi
        elif [ $(( (a - b) * 100 )) -gt $(( THRESHOLD_PCT * b )) ]; then
            echo "  REGRESSION: $name  Ir ${b} -> ${a}  (+${inc}% > ${THRESHOLD_PCT}%)"; fail=1
        else
            echo "  ok: $name  Ir ${a}  (${inc}% vs ref)"
        fi
    done
    # Every declared bench row was applied (a declaration no workload used is
    # a bound that guards nothing).
    [ "$used" -eq "$ndecl" ] || { echo "  FAIL: declared bench rows=$ndecl applied=$used"; exit 2; }
    [ "$fail" -eq 0 ] && echo "no instruction-count regressions vs reference (threshold ${THRESHOLD_PCT}%; declared rows applied=$used)"
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
