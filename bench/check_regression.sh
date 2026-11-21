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
#   bench/check_regression.sh --vs BASE NAMED # compare using base and named reference builds
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
# --vs measures every codspeed.yml workload in both tiers
# (tools/phase2_cost.sh --population), so its own CI log can re-declare every max_ci (#1939).
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
    # R22-2: division by zero is IEEE, so use the same DIV expression with
    # a string operand to keep this a real runtime failure in every mode.
    printf 'print of (1 / "bad")\n' > "$bad"
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

    # The --vs cases run in a scratch checkout against a ledger written there, so no case depends on
    # what tests/phase2/cost_expect.txt declares today (its rows leave one by one; it is empty at a release).
    scratch=$(mktemp -d)
    measure_log="$scratch/measure.log"
    profiler="$scratch/valgrind"
    profiler_source="$scratch/valgrind.py"
    current="$scratch/current"
    reference="$scratch/reference"
    named_reference="$scratch/named-reference"
    printf '#!/bin/sh\nexit 0\n' > "$current"
    cp "$current" "$reference"
    cp "$current" "$named_reference"
    # The stand-in profiler: every count is 1000000 except the planted row's and the candidate's count of
    # the row whose two maxima differ. Which rows those are is passed in (BENCH_SELFTEST_DECLARED,
    # _UNDECLARED and _SPLIT, chosen below by position), never written here.
    cat > "$profiler_source" <<'EOF'
import os
from pathlib import Path
import sys

root = Path(os.environ['BENCH_SELFTEST_ROOT']).resolve()
binary, file = map(Path, sys.argv[-2:])
tier = 'off' if os.environ.get('EIGS_JIT_OFF') == '1' else 'jit'
row = file.resolve().relative_to(root).as_posix() + '\t' + tier
with open(os.environ['MEASURE_LOG'], 'a') as log:
    log.write(f'{binary.name}\t{row}\n')
plant = os.environ.get('BENCH_SELFTEST_PLANT', '')
# (current, reference = the base, named-reference); a declared row's max is 0.3 in both columns,
# except the split row's (0.3 local, 5.8 CI), whose candidate is always +5.5% over the named reference.
counts = {
    'declared-over': (1013000, 1000000, 1000000),        # +1.3% > 0.3
    'declared-stale': (990000, 1000000, 1000000),        # -1.0% < 0.3 - 0.5
    'deleted-declaration': (1060000, 1060000, 1000000),  # base holds the candidate's tree: +6% vs named only
    'undeclared-base-fail': (2000000, 1000000, 2000000),
    'undeclared-pass': (1000000, 1000000, 960000),
    'undeclared-named-fail': (1300000, 1300000, 1000000),
}.get(plant)
target = os.environ['BENCH_SELFTEST_' + ('UNDECLARED' if plant.startswith('undeclared') else 'DECLARED')]
count = 1055000 if row == os.environ['BENCH_SELFTEST_SPLIT'] and binary.name == 'current' else 1000000
if counts and row == target:
    count = counts[('current', 'reference', 'named-reference').index(binary.name)]
print(f'I refs: {count}')
EOF
    python_executable=$(python3 -c 'import sys; print(sys.executable)') || exit 1
    printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$python_executable" "$profiler_source" > "$profiler"
    chmod +x "$profiler" "$current" "$reference" "$named_reference"
    # A checkout of THIS tree (the population is derived with `git ls-files`); what differs from HEAD
    # is brought over and staged there, so a gate, or a workload added or removed, that is not committed
    # yet tests itself. No registered worktree stays.
    st="$scratch/selftest-tree"
    trap 'git -C "$DIR/.." worktree remove --force "$st" >/dev/null 2>&1; rm -rf "$scratch"' EXIT
    git -C "$DIR/.." worktree add --quiet --detach "$st" HEAD || exit 1
    { git -C "$DIR/.." diff --name-only -z HEAD; git -C "$DIR/.." ls-files -o --exclude-standard -z; } |
        while IFS= read -r -d '' changed; do
            if [ -e "$DIR/../$changed" ]; then
                mkdir -p "$st/$(dirname "$changed")" && cp -p "$DIR/../$changed" "$st/$changed" || exit 1
            else
                rm -f "$st/$changed"
            fi
        done || exit 1
    git -C "$st" add -A || exit 1
    gate="$st/bench/check_regression.sh"
    ledger="$st/tests/phase2/cost_expect.txt"
    "$gate" --list-vs > "$scratch/population" || exit 1
    # The population's size, derived apart from the gate's own derivation: every tracked workload, two tiers.
    want_rows=$(( 2 * $(git -C "$st" ls-files ':(glob)bench/*.eigs' ':(glob)tests/bench_*.eigs' | wc -l) ))
    [ "$want_rows" -ge 4 ] && [ "$(wc -l < "$scratch/population")" -eq "$want_rows" ] \
        || { echo "SELFTEST FAILED: --list-vs printed $(wc -l < "$scratch/population") rows, tracked workloads give $want_rows"; exit 1; }
    # The written ledger declares every row (max 0.3 in both columns, so equal counts are ok) except the
    # population's second row; its first row is the declared row the plants move, and its third is
    # declared 0.3 local and 5.8 CI, so the control holds which column judges a declared row.
    export BENCH_SELFTEST_DECLARED BENCH_SELFTEST_UNDECLARED BENCH_SELFTEST_SPLIT
    BENCH_SELFTEST_DECLARED=$(sed -n 1p "$scratch/population"); BENCH_SELFTEST_UNDECLARED=$(sed -n 2p "$scratch/population")
    BENCH_SELFTEST_SPLIT=$(sed -n 3p "$scratch/population")
    write_ledger() { # the rows (workload TAB tier) that get no declaration
        awk -v a="$1" -v b="${2:-}" -v s="$BENCH_SELFTEST_SPLIT" '$0 != a && $0 != b {
            print $0 "\t0.3\t" ($0 == s ? "5.8" : "0.3") "\tR5\tbench self-test declaration" }' \
            "$scratch/population" > "$ledger"
    }
    write_ledger "$BENCH_SELFTEST_UNDECLARED" || exit 1
    want_decl=$(bash "$st/tools/phase2_cost.sh" --declared all --method ci | awk 'NF {n++} END {print n+0}') || exit 1
    [ "$want_decl" -eq $(( want_rows - 1 )) ] || { echo "SELFTEST FAILED: the written ledger gives $want_decl declarations for $want_rows rows"; exit 1; }
    if ! BENCH_SELFTEST_ROOT="$st" MEASURE_LOG="$measure_log" VALGRIND="$profiler" EIGENSCRIPT="$current" "$gate" --vs "$reference" "$named_reference" >"$scratch/population.out" 2>&1; then
        cat "$scratch/population.out"
        echo "SELFTEST FAILED: valid derived benchmark population was rejected"; exit 1
    fi
    if ! grep -Fxq "no instruction-count regressions vs reference (threshold ${THRESHOLD_PCT}%; declared rows applied=${want_decl}; measured rows=${want_rows})" "$scratch/population.out"; then
        cat "$scratch/population.out"
        echo "SELFTEST FAILED: clean control did not print declared rows applied=${want_decl}; measured rows=${want_rows}"; exit 1
    fi
    echo "SELFTEST OK: a base that holds the candidate's tree passes (declared rows applied=${want_decl}; measured rows=${want_rows})"
    if ! grep -qF "DECLARED: ${BENCH_SELFTEST_SPLIT%$'\t'*} tier=${BENCH_SELFTEST_SPLIT#*$'\t'} " "$scratch/population.out"; then
        cat "$scratch/population.out"
        echo "SELFTEST FAILED: the row declared 0.3 local and 5.8 CI did not print DECLARED at +5.5%"; exit 1
    fi
    echo "SELFTEST OK: a declared row is judged by its CI maximum (0.3 local, 5.8 CI: +5.5% is DECLARED)"
    # Expected measurements: every row on the candidate and the named reference, the base only for
    # rows with no declaration. Both lists come from the population and the row the ledger leaves undeclared.
    while IFS= read -r row; do
        printf 'current\t%s\nnamed-reference\t%s\n' "$row" "$row"
        [ "$row" != "$BENCH_SELFTEST_UNDECLARED" ] || printf 'reference\t%s\n' "$row"
    done < "$scratch/population" | sort > "$scratch/expected"
    if ! sort "$measure_log" | cmp -s - "$scratch/expected"; then
        echo "SELFTEST FAILED: a workload/tier was skipped or measured more than once"; exit 1
    fi
    echo "SELFTEST OK: every derived workload/tier is measured once"
    BENCH_SELFTEST_ROOT="$st" MEASURE_LOG="$measure_log" VALGRIND="$profiler" EIGENSCRIPT="$current" \
      "$gate" --vs "$reference" >"$scratch/one-binary.out" 2>&1
    got_rc=$?
    if [ "$got_rc" -ne 2 ] || ! grep -q 'requires base and named-reference binaries' "$scratch/one-binary.out"; then
        cat "$scratch/one-binary.out"
        echo "SELFTEST FAILED: --vs with one binary was not refused (rc=$got_rc)"; exit 1
    fi
    echo "SELFTEST OK: --vs with one binary is refused (no named reference)"
    run_plant() { # environment value, expected verdict, row (workload TAB tier), expected rc
        plant_name=$1 verdict=$2 row=$3 want_rc=$4
        BENCH_SELFTEST_PLANT="$plant_name" BENCH_SELFTEST_ROOT="$st" \
          MEASURE_LOG="$measure_log" VALGRIND="$profiler" EIGENSCRIPT="$current" \
          "$gate" --vs "$reference" "$named_reference" >"$scratch/$plant_name.out" 2>&1
        got_rc=$?
        if [ "$got_rc" -ne "$want_rc" ] || ! grep -qF "$verdict: ${row%$'\t'*} tier=${row#*$'\t'} " "$scratch/$plant_name.out"; then
            cat "$scratch/$plant_name.out"
            echo "SELFTEST FAILED: $plant_name did not produce $verdict for ${row/$'\t'/ } (rc=$got_rc)"; exit 1
        fi
        echo "SELFTEST OK: $plant_name produces $verdict for ${row/$'\t'/ }"
    }
    run_plant declared-over REGRESSION "$BENCH_SELFTEST_DECLARED" 1
    run_plant declared-stale 'STALE DECLARATION' "$BENCH_SELFTEST_DECLARED" 1
    run_plant undeclared-base-fail REGRESSION "$BENCH_SELFTEST_UNDECLARED" 1
    run_plant undeclared-pass ok "$BENCH_SELFTEST_UNDECLARED" 0
    run_plant undeclared-named-fail REGRESSION "$BENCH_SELFTEST_UNDECLARED" 1
    # A declaration deleted without its cost being recovered: the base equals the candidate, so only
    # the named reference can reject the row.
    write_ledger "$BENCH_SELFTEST_UNDECLARED" "$BENCH_SELFTEST_DECLARED" || exit 1
    run_plant deleted-declaration REGRESSION "$BENCH_SELFTEST_DECLARED" 1
    git -C "$DIR/.." worktree remove --force "$st" || exit 1
    trap - EXIT
    rm -rf "$scratch"
    exit 0 ;;
--vs|--list-vs)
    # Base and candidate use this gate's own measurement recipe. Its CI
    # counts, including off-tier declarations, are the source of max_ci.
    ref="${2:-}"; named="${3:-}"; fail=0; used=0; named_rows=0; base_rows=0
    if [ "$1" = --vs ] && { [ -z "$ref" ] || [ -z "$named" ]; }; then
        echo "  FAIL: --vs requires base and named-reference binaries"; exit 2
    fi
    decl=$(bash "$DIR/../tools/phase2_cost.sh" --declared all --method ci) \
        || { echo "  FAIL: cannot read the declared costs (tools/phase2_cost.sh --declared all --method ci)"; exit 2; }
    ndecl=$(awk 'NF {n++} END {print n+0}' <<< "$decl")
    work=$(mktemp -d "${TMPDIR:-/tmp}/eigs-bench-vs.XXXXXX") || exit 2
    trap 'rm -rf "$work"' EXIT
    bash "$DIR/../tools/phase2_cost.sh" --population > "$work/population" \
        || { echo "  FAIL: cannot derive the CodSpeed population"; exit 2; }
    if [ "$1" = --list-vs ]; then cat "$work/population"; exit 0; fi
    nrows=$(wc -l < "$work/population")
    echo "  tiers: explicit jit/off (caller EIGS_* unset); column: max_ci; stale_below_max=0.5; declared rows: $ndecl; measured rows: $nrows"
    while IFS=$'\t' read -r workload tier; do
        f="$DIR/../$workload"
        [ -f "$f" ] || { echo "  FAIL: missing workload: $workload"; exit 2; }
        a=$(ir_of "$EIGS" "$f" "$tier") || exit $?
        row=$(awk -F'\t' -v w="$workload" -v t="$tier" '$1 == w && $2 == t' <<< "$decl")
        n=$(ir_of "$named" "$f" "$tier") || exit $?
        [[ "$a" =~ ^[1-9][0-9]*$ && "$n" =~ ^[1-9][0-9]*$ ]] \
            || { echo "  FAIL: $workload $tier: no instruction count (cand='$a' named='$n')"; exit 2; }
        if [ -n "$row" ]; then used=$((used + 1)); else
            b=$(ir_of "$ref" "$f" "$tier") || exit $?
            [[ "$b" =~ ^[1-9][0-9]*$ ]] || { echo "  FAIL: $workload $tier: no base instruction count"; exit 2; }
            python3 "$DIR/../tools/phase2_cost_declarations.py" --method ci \
                --row "$workload" "$tier" "$b" "$a"
            rc=$?; [ "$rc" -le 1 ] || exit "$rc"; [ "$rc" -eq 0 ] || fail=1
            base_rows=$((base_rows + 1))
        fi
        # Declared rows use the named pre-number-model build; undeclared rows
        # must pass both that comparison and the candidate-base comparison.
        python3 "$DIR/../tools/phase2_cost_declarations.py" --method ci \
            --row "$workload" "$tier" "$n" "$a"
        rc=$?
        named_rows=$((named_rows + 1))
        [ "$rc" -le 1 ] || exit "$rc"
        [ "$rc" -eq 0 ] || fail=1
    done < "$work/population"
    # Every declaration was measured exactly once, regardless of workload dir
    # or tier. The union's population is derived, never hand-maintained.
    [ "$used" -eq "$ndecl" ] || { echo "  FAIL: declared rows=$ndecl applied=$used"; exit 2; }
    if [ "$fail" -eq 0 ]; then
        echo "no instruction-count regressions vs reference (threshold ${THRESHOLD_PCT}%; declared rows applied=$used; measured rows=$nrows)"
        echo "judged rows: named reference=$named_rows; candidate base=$base_rows"
    fi
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
