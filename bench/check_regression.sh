#!/bin/bash
# Deterministic perf regression gate (#398). Wall-clock medians flake on shared
# CI runners, so the GATE uses cachegrind instruction counts (Ir) instead:
# same binary + same input in one environment gives a diffable instruction
# count; glibc ifunc selection can vary across hosts (#1939). The --vs
# threshold is THRESHOLD_PCT; checked-in files use FILE_THRESHOLD_PCT.
#
#   bench/check_regression.sh            # gate: compare vs bench/baseline.txt
#   bench/check_regression.sh --update   # regenerate the baseline
#   bench/check_regression.sh --selftest # prove a 2x-work pessimization is caught
#   bench/check_regression.sh --list-vs  # derived --vs workload/tier population
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="${EIGENSCRIPT:-$DIR/../src/eigenscript}"
BASELINE="${BASELINE_OVERRIDE:-$DIR/baseline.txt}"
VALGRIND="${VALGRIND:-valgrind}"
THRESHOLD_PCT=0.5
# Integer arithmetic keeps the boundary exact: 0.5 percent is 5 permille.
# Keep this derived rather than maintaining a second threshold declaration.
THRESHOLD_PERMILLE=$(awk -v pct="$THRESHOLD_PCT" 'BEGIN { printf "%.0f", pct * 10 }')
# THRESHOLD_PCT (0.5) is measured for SAME-JOB comparisons only (#2072: --vs,
# base and candidate on one machine). The checked-in baseline file is compared
# across hosts, where glibc's CPU-specific strlen/memcpy ifuncs move Ir by up to
# 0.72% (Intel vs EPYC, #2002). That term is unmeasured, so the file mode keeps
# its own wider threshold until a cross-host measurement sets it.
FILE_THRESHOLD_PCT=5
FILE_THRESHOLD_PERMILLE=$(( FILE_THRESHOLD_PCT * 10 ))
# Printed deltas carry 3 decimals. Integer percent printed "+0% > 0.5%" for a
# +0.61% regression and "0% vs ref" for every passing row, hiding the deltas the
# 0.5% gate decides on (#2075's ejection, 2026-10-28). Display only: the verdicts
# above and below stay exact integer permille comparisons.
pct() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", (a - b) * 100 / b }'; }

# Drop caller EIGS_* settings, then select the requested tier explicitly.
# --vs measures the union of bench/*.eigs (default JIT) and every declared
# workload/tier pair, so its own CI log can re-declare every max_ci (#1939).
ir_of() {  # ir_of <binary> <file> [jit|off] -> instruction count
    local tier="${3:-jit}" tier_env=
    case "$tier" in jit) ;; off) tier_env=EIGS_JIT_OFF=1 ;; *) return 2 ;; esac
    # Capture the producer before parsing it.  This is the standard portable
    # shell pattern when a pipeline must preserve an earlier command's status
    # (rather than relying on the pipeline's final command or bash pipefail).
    out=$(mktemp) || return
    env $(compgen -e | grep '^EIGS_' | sed 's/^/-u /') $tier_env \
        "$VALGRIND" --tool=cachegrind --cachegrind-out-file=/dev/null "$1" "$2" >"$out" 2>&1
    status=$?
    if [ "$status" -ne 0 ]; then
        cat "$out" >&2
        rm -f "$out"
        return "$status"
    fi
    count=$(grep -oE "I *refs:[ ]*[0-9,]+" "$out" | grep -oE "[0-9,]+" | tr -d ',')
    parse_status=$?
    rm -f "$out"
    if [ "$parse_status" -ne 0 ] || ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -le 0 ]; then
        echo "invalid cachegrind I refs summary" >&2
        return 1
    fi
    printf '%s\n' "$count"
}

case "${1:-}" in
--update)
    : > "$BASELINE"
    for f in "$DIR"/*.eigs; do
        count=$(ir_of "$EIGS" "$f") || exit $?
        echo "$(basename "$f" .eigs) $count" >> "$BASELINE"
    done
    echo "baseline updated:"; cat "$BASELINE"; exit 0 ;;
--selftest)
    base=$(ir_of "$EIGS" "$DIR/scalar_loop.eigs") || exit $?
    tmp=$(mktemp --suffix=.eigs)
    # ~2x the iterations of scalar_loop => ~2x instructions, well over threshold.
    printf 'total is 0\nfor i in range of 80000:\n    total is total + (i * 2) - 1\nprint of total\n' > "$tmp"
    doubled=$(ir_of "$EIGS" "$tmp") || { status=$?; rm -f "$tmp"; exit "$status"; }; rm -f "$tmp"
    inc=$(pct "$doubled" "$base")
    if [ $(( (doubled - base) * 1000 )) -gt $(( THRESHOLD_PERMILLE * base )) ]; then
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
    rm -f "$fake"; echo "SELFTEST OK: a 2x-stale baseline is flagged"

    # A real runtime error still leaves cachegrind's positive summary behind.
    # The profiler's nonzero status, not that superficially valid count, must
    # decide the gate result.
    bad=$(mktemp --suffix=.eigs)
    plant=$(mktemp)
    printf 'print of (1 / 0)\n' > "$bad"
    printf '#!/bin/sh\n"%s" "%s"\nstatus=$?\necho "I refs: 1,000" >&2\nexit "$status"\n' "$EIGS" "$bad" > "$plant"
    chmod +x "$plant"
    diagnostic=$(mktemp)
    if ir_of "$plant" "$DIR/scalar_loop.eigs" >/dev/null 2>"$diagnostic"; then
        rm -f "$bad" "$plant" "$diagnostic"
        echo "SELFTEST FAILED: nonzero runtime with a positive Ir summary passed"; exit 1
    fi
    if ! grep -qE 'I *refs:[ ]*[1-9][0-9,]*' "$diagnostic"; then
        rm -f "$bad" "$plant" "$diagnostic"
        echo "SELFTEST FAILED: runtime failure plant emitted no positive Ir summary"; exit 1
    fi
    rm -f "$bad" "$plant" "$diagnostic"
    echo "SELFTEST OK: nonzero runtime with a positive Ir summary is rejected"

    # Derive the workload population from the same source glob as the gate and
    # prove each of the current/reference tiers is measured exactly once.
    scratch=$(mktemp -d)
    measure_log="$scratch/measure.log"
    profiler="$scratch/valgrind"
    current="$scratch/current"
    reference="$scratch/reference"
    printf '#!/bin/sh\nexit 0\n' > "$current"
    cp "$current" "$reference"
    # Equal synthetic counts would make real declared costs STALE. Keep the
    # full population and give each declared row counts inside its own band.
    cat > "$profiler" <<'EOF'
#!/usr/bin/env python3
from decimal import Decimal
import os
from pathlib import Path
import sys

root = Path(os.environ['BENCH_SELFTEST_ROOT']).resolve()
sys.path.insert(0, str(root / 'tools'))
from phase2_cost_declarations import NOISE, parse_declarations

binary, file = map(Path, sys.argv[-2:])
workload = file.resolve().relative_to(root).as_posix()
tier = 'off' if os.environ.get('EIGS_JIT_OFF') == '1' else 'jit'
with open(os.environ['MEASURE_LOG'], 'a') as log:
    log.write(f'{binary.name}\t{workload}\t{tier}\n')
declarations = parse_declarations((root / 'tests/phase2/cost_expect.txt').read_text())
declaration = declarations.get((workload, tier))
count = 1000000
if binary.name == 'current' and declaration:
    delta = max(Decimal(0), declaration.max_ci - NOISE)
    count = int(Decimal(count) * (1 + delta / 100))
print(f'I refs: {count}')
EOF
    chmod +x "$profiler" "$current" "$reference"
    if ! BENCH_SELFTEST_ROOT="$DIR/.." MEASURE_LOG="$measure_log" VALGRIND="$profiler" EIGENSCRIPT="$current" "$0" --vs "$reference" >"$scratch/population.out" 2>&1; then
        cat "$scratch/population.out"
        rm -rf "$scratch"
        echo "SELFTEST FAILED: valid derived benchmark population was rejected"; exit 1
    fi
    expected="$scratch/expected"
    "$0" --list-vs > "$scratch/population" || exit 1
    while IFS=$'\t' read -r workload tier; do
        printf 'current\t%s\t%s\nreference\t%s\t%s\n' "$workload" "$tier" "$workload" "$tier"
    done < "$scratch/population" | sort > "$expected"
    if ! sort "$measure_log" | cmp -s - "$expected"; then
        rm -rf "$scratch"
        echo "SELFTEST FAILED: a workload/tier was skipped or measured more than once"; exit 1
    fi
    rm -rf "$scratch"
    echo "SELFTEST OK: every derived workload/tier is measured once"
    exit 0 ;;
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
        a=$(ir_of "$EIGS" "$f" "$tier") || exit $?
        b=$(ir_of "$ref" "$f" "$tier") || exit $?
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
    cur=$(ir_of "$EIGS" "$f") || exit $?
    inc=$(pct "$cur" "$base")
    if [ $(( (cur - base) * 1000 )) -gt $(( FILE_THRESHOLD_PERMILLE * base )) ]; then
        echo "  REGRESSION: $name  Ir ${base} -> ${cur}  (+${inc}% > ${FILE_THRESHOLD_PCT}%)"; fail=1
    elif [ $(( (cur - base) * 1000 )) -lt $(( -FILE_THRESHOLD_PERMILLE * base )) ]; then
        echo "  STALE BASELINE: $name  Ir ${base} -> ${cur}  (${inc}%, gate would be measuring less)"; stale=1
    else
        echo "  ok: $name  Ir ${cur}  (${inc}% vs baseline)"
    fi
done < "$BASELINE"
if [ "$stale" -eq 1 ]; then
    echo "baseline is stale by more than ${FILE_THRESHOLD_PCT}% on at least one workload — run: $0 --update (and commit bench/baseline.txt)"
    fail=1
fi
[ "$fail" -eq 0 ] && echo "no instruction-count regressions (threshold ${FILE_THRESHOLD_PCT}%, two-sided)"
exit $fail
