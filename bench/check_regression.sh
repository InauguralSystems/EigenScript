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

ir_of() {  # ir_of <binary> <file> -> instruction count
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
    ref="$2"; fail=0
    for f in "$DIR"/*.eigs; do
        name=$(basename "$f" .eigs)
        a=$(ir_of "$EIGS" "$f")
        b=$(ir_of "$ref" "$f")
        inc=$(( (a - b) * 100 / b ))
        if [ "$inc" -gt "$THRESHOLD_PCT" ]; then
            echo "  REGRESSION: $name  Ir ${b} -> ${a}  (+${inc}% > ${THRESHOLD_PCT}%)"; fail=1
        else
            echo "  ok: $name  Ir ${a}  (${inc}% vs ref)"
        fi
    done
    [ "$fail" -eq 0 ] && echo "no instruction-count regressions vs reference (threshold ${THRESHOLD_PCT}%)"
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
    if [ "$inc" -gt "$THRESHOLD_PCT" ]; then
        echo "  REGRESSION: $name  Ir ${base} -> ${cur}  (+${inc}% > ${THRESHOLD_PCT}%)"; fail=1
    elif [ "$inc" -lt "-$THRESHOLD_PCT" ]; then
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
