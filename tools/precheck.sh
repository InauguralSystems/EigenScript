#!/usr/bin/env bash
# Contributor precheck (#1264): the repo's STATIC gates, locally, plus changed-gate self-tests, one line per gate, exit 1 if any fails. `make precheck` runs this.
#
# PR #1260 (a correct 5-line fix) met four of these gates one at a time, each
# after a ~45-minute CI run, though every one is decidable from the tree.
#
# ONE LIST. The GATES table below is the only copy: CI runs this script itself
# (.github/workflows/ci.yml, job gate-selftests), so the precheck cannot drift
# from what CI runs — a gate listed here is a gate CI runs.
# `bin` rows need a built eigenscript and SKIP (named) without one; `make` first.
#
# The diff base of the base-relative rows is PRECHECK_BASE (default origin/main, for local use). CI sets it to the
# event's base: pull_request.base.sha, or merge_group.base_sha (the candidate's base, NOT main's tip).
#
# Usage: tools/precheck.sh [--list|--selftest]
set -u
cd "$(dirname "$0")/.." || exit 2
. tools/portability_verdict.sh

run_gate() {   # run_gate <index> <class> <command...>
    local i="$1" class="$2" s rc; shift 2
    if { [ "$class" = bin ] || [ "$class" = portability ] || [ "$class" = selftest ]; } && [ -z "$BIN" ]; then
        echo "SKIP|0|no eigenscript binary (run make to include this gate)" > "$OUT/$i.st"; return
    fi
    s=$(date +%s)
    bash "$@" > "$OUT/$i.log" 2>&1; rc=$?
    if [ "$class" = portability ]; then
        portability_verdict "$rc" "$(cat "$OUT/$i.log")" "${PRECHECK_KERNEL:-$(uname -s)}"
        echo "$PORT_VERDICT|$(( $(date +%s) - s ))|$PORT_VERDICT_REASON" > "$OUT/$i.st"
    elif [ "$rc" -eq 0 ]; then
        # Only gates with an explicit classifier may announce a whole-gate
        # skip.  A sub-check's `name: SKIPPED` can never mask this row's PASS.
        echo "PASS|$(( $(date +%s) - s ))|$(grep -v '^[[:space:]]*$' "$OUT/$i.log" | tail -1 | cut -c1-120)" > "$OUT/$i.st"
    else
        echo "FAIL|$(( $(date +%s) - s ))|exit $rc" > "$OUT/$i.st"
    fi
}

if [ "${1:-}" = --selftest ]; then
    OUT=$(mktemp -d "${TMPDIR:-/tmp}/eigs_precheck_selftest.XXXXXX") || exit 2
    trap 'rm -rf "$OUT"' EXIT
    stub="$OUT/gate.sh"
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$2"' 'exit "$1"' > "$stub"
    chmod +x "$stub"
    BIN=selftest-binary
    fail=0
    check() { # name command-rc expected-status output [kernel]
        local name="$1" rc="$2" want="$3" out="$4" kernel="${5:-Linux}"
        PRECHECK_KERNEL="$kernel" run_gate "$name" portability "$stub" "$rc" "$out"
        IFS='|' read -r got _ reason < "$OUT/$name.st"
        if [ "$got" = "$want" ]; then echo "PASS: $name -> $want"
        else echo "FAIL: $name wanted $want, got $got ($reason)"; fail=$((fail + 1)); fi
    }
    check pass 0 PASS $'portability-parse: oracle-major=3\nportability: OK: complete'
    check fail 7 FAIL 'portability: FAIL: planted'
    check announced-skip 0 SKIP 'portability-parse: SKIPPED (planted)'
    check no-verdict 0 FAIL ''
    check both-verdicts 0 FAIL $'portability-parse: oracle-major=3\nportability-parse: SKIPPED\nportability: OK:'
    check wrong-identity 0 FAIL $'portability-parse: oracle-major=5\nportability: OK:'
    check darwin-skip 0 FAIL 'portability-parse: SKIPPED' Darwin
    run_gate generic-pass run "$stub" 0 'nested-check: SKIPPED'
    IFS='|' read -r got _ _ < "$OUT/generic-pass.st"
    [ "$got" = PASS ] && echo 'PASS: generic gate -> PASS' || { echo "FAIL: generic gate wanted PASS, got $got"; fail=$((fail + 1)); }
    run_gate generic-fail run "$stub" 7 'planted failure'
    IFS='|' read -r got _ _ < "$OUT/generic-fail.st"
    [ "$got" = FAIL ] && echo 'PASS: failing gate -> FAIL' || { echo "FAIL: failing gate wanted FAIL, got $got"; fail=$((fail + 1)); }
    BIN=""; run_gate no-binary bin "$stub" 99 'must not run'
    IFS='|' read -r got _ _ < "$OUT/no-binary.st"
    [ "$got" = SKIP ] && echo 'PASS: no binary -> SKIP' || { echo "FAIL: no binary wanted SKIP, got $got"; fail=$((fail + 1)); }
    echo "precheck-selftest: $((10 - fail))/10 passed, $fail failed"
    [ "$fail" -eq 0 ]; exit
fi

# The shard count is ci.yml's, so this checks the plan CI checks.
SHARDS=$(sed -n 's/^[[:space:]]*ASAN_SHARDS:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' .github/workflows/ci.yml | head -1)
[ -n "$SHARDS" ] || { echo "precheck: ABORTED: no ASAN_SHARDS in .github/workflows/ci.yml"; exit 2; }

BASE=${PRECHECK_BASE:-origin/main}

# class | command   (lane = alternate rows; the slow ones are spread by order)
GATES="run|tools/core_ext_boundary_check.sh
run|tools/pipefail_verdict_check.sh
bin|tools/docs_claims_check.sh
run|tools/section_plan.sh --shards $SHARDS --check
run|tools/workflow_yaml_check.sh
run|tools/ci_tier_check.sh
run|tools/child_exit_check.sh
run|tools/enrolment_check.sh
run|tools/suite_label_check.sh
run|tools/obs_marker_check.sh
run|tools/obs_reader_sync_check.sh
run|tools/vm_operand_width_check.sh
run|tools/stdlib_index_check.sh
run|tools/ui_surface_check.sh
run|tools/codspeed_targets_check.sh
run|tools/gfx_guard_order_check.sh
run|tools/changelog_fragments.sh check $BASE
portability|tools/portability_parse_check.sh
selftest|tools/selftests.sh --changed $BASE"

if [ "${1:-}" = "--list" ]; then printf '%s\n' "$GATES" | tr '|' ' '; exit 0; fi
[ -z "${1:-}" ] || { echo "usage: tools/precheck.sh [--list|--selftest]" >&2; exit 2; }

BIN=""
for b in src/eigenscript build/release/eigenscript; do [ -x "$b" ] && { BIN=$b; break; }; done
OUT=$(mktemp -d "${TMPDIR:-/tmp}/eigs_precheck.XXXXXX") || exit 2
trap 'rm -rf "$OUT"' EXIT
T0=$(date +%s)

lane() {   # two lanes (bash 3.2 has no `wait -n`): every other row
    local i=0 class cmd
    while IFS='|' read -r class cmd; do
        [ "$class" != selftest ] && [ $((i % 2)) -eq "$1" ] && run_gate "$i" "$class" $cmd
        i=$((i + 1))
    done <<< "$GATES"
}
lane 0 & p0=$!
lane 1 & p1=$!
wait "$p0" "$p1"
# The self-tests can build scratch fixtures: run serially after the static lanes.
# CI owns this row separately, with the event's base SHA rather than origin/main.
i=0
while IFS='|' read -r class cmd; do
    if [ "$class" = selftest ]; then
        if [ "${PRECHECK_SELFTESTS:-1}" = 0 ]; then
            echo "SKIP|0|CI runs the driver separately with the event base SHA" > "$OUT/$i.st"
        else
            run_gate "$i" "$class" $cmd
            cat "$OUT/$i.log"
        fi
    fi
    i=$((i + 1))
done <<< "$GATES"

pass=0; fail=0; skip=0; i=0
while IFS='|' read -r class cmd; do
    if [ -f "$OUT/$i.st" ]; then IFS='|' read -r st secs msg < "$OUT/$i.st"
    else st=FAIL; secs=0; msg="no result: the lane died"; fi
    printf '  %-4s %-46s %3ss  %s\n' "$st" "$cmd" "$secs" "$msg"
    case "$st" in
        PASS) pass=$((pass + 1)) ;;
        SKIP) skip=$((skip + 1)) ;;
        *)    fail=$((fail + 1))
              grep -E 'FAIL|ERROR|RED|ABORT|BROKEN' "$OUT/$i.log" 2>/dev/null | head -6 | sed 's/^/        /'
              echo "        (full output: bash $cmd)" ;;
    esac
    i=$((i + 1))
done <<< "$GATES"
# Every row must have produced a verdict (a gate that ran nothing is not a pass).
[ $((pass + fail + skip)) -eq "$i" ] && [ "$i" -gt 0 ] || { echo "precheck: ABORTED: $((pass + fail + skip)) results for $i gates"; exit 2; }
echo "precheck: $pass passed, $fail failed, $skip skipped in $(( $(date +%s) - T0 ))s"
[ "$fail" -eq 0 ]
