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

set_tool_runner() { # set the interpreter used for a tool path
    case "$1" in
        *.py) TOOL_RUNNER=python3 ;;
        *) TOOL_RUNNER=bash ;;
    esac
}

print_full_output_hint() { # <command string>
    local cmd="$1"
    set_tool_runner "${cmd%% *}"
    printf '        (full output: %s %s)\n' "$TOOL_RUNNER" "$cmd"
}

# One line for each row of $GATES from its $OUT/<index>.st; under a failing row its
# red lines and the hint. Sets pass, fail, skip and i. The self-test calls this same
# function on seven rows and compares the whole report with its expected text.
report_rows() {
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
                  print_full_output_hint "$cmd" ;;
        esac
        i=$((i + 1))
    done <<< "$GATES"
}

run_gate() {   # run_gate <index> <class> <command...>
    local i="$1" class="$2" s rc; shift 2
    if { [ "$class" = bin ] || [ "$class" = portability ] || [ "$class" = selftest ]; } && [ -z "$BIN" ]; then
        : > "$OUT/$i.log"
        echo "SKIP|0|no eigenscript binary (run make to include this gate)" > "$OUT/$i.st"; return
    fi
    s=$(date +%s)
    set_tool_runner "$1"
    "$TOOL_RUNNER" "$@" > "$OUT/$i.log" 2>&1; rc=$?
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
    [ "$got" = PASS ] && [ "$(cat "$OUT/generic-pass.log" 2>&1)" = 'nested-check: SKIPPED' ] && echo 'PASS: generic gate -> PASS with log' || { echo "FAIL: generic gate wanted PASS with log, got $got"; fail=$((fail + 1)); }
    run_gate generic-fail run "$stub" 7 'planted failure'
    IFS='|' read -r got _ _ < "$OUT/generic-fail.st"
    [ "$got" = FAIL ] && [ "$(cat "$OUT/generic-fail.log" 2>&1)" = 'planted failure' ] && echo 'PASS: failing gate -> FAIL with log' || { echo "FAIL: failing gate wanted FAIL with log, got $got"; fail=$((fail + 1)); }
    BIN=""; run_gate no-binary selftest "$stub" 99 'must not run'
    IFS='|' read -r got _ _ < "$OUT/no-binary.st"
    [ "$got" = SKIP ] && [ -f "$OUT/no-binary.log" ] && [ ! -s "$OUT/no-binary.log" ] && echo 'PASS: no binary -> SKIP with empty log' || { echo "FAIL: no binary wanted SKIP with empty log, got $got"; fail=$((fail + 1)); }
    # The report of a failing precheck, from the function the precheck itself calls, compared
    # whole with the text written out here: seven rows (a failing Python row with an argument
    # whose log holds each word the red-line filter knows, a red line that begins with `#` as
    # tools/section_plan.sh prints them, an ordinary line and two more red lines; a failing shell row; a passing row; a failing row of class portability; a row that
    # left no result; a skipped row; a passing row of class bin), with the times set by hand.
    py_stub="$OUT/failing.py"
    printf '%s\n' 'import sys' \
        'for line in ("planted FAIL in python", "an ERROR line", "a RED line", "an ABORT line",' \
        '             "a BROKEN line", "# a FAIL line that begins with a hash", "an ordinary line",' \
        '             "seventh FAIL line", "eighth FAIL line"):' \
        '    print(line)' 'sys.exit(7)' > "$py_stub"
    BIN=selftest-binary
    py_cmd="$py_stub --flag"
    sh_cmd="$stub 7 planted-FAIL"
    other_cmd="$stub 7 portability:-FAIL:-planted"
    lost_cmd="$stub 9 never-ran"
    run_gate 0 run $py_cmd
    run_gate 1 run $sh_cmd
    run_gate 2 run "$stub" 0 ok
    PRECHECK_KERNEL=Linux run_gate 3 portability $other_cmd
    BIN="" run_gate 5 selftest "$stub" 99 must-not-run
    run_gate 6 bin "$stub" 0 bin-ok
    for n in 0 1 2 3 5 6; do
        IFS='|' read -r st _ msg < "$OUT/$n.st"
        echo "$st|$((n + 11))|$msg" > "$OUT/$n.st"
    done
    report=$({ GATES="run|$py_cmd"$'\n'"run|$sh_cmd"$'\n'"run|$stub 0 ok"$'\n'"portability|$other_cmd"$'\n'"run|$lost_cmd"$'\n'"selftest|$stub 99 must-not-run"$'\n'"bin|$stub 0 bin-ok"
               report_rows; echo "counted: $pass passed, $fail failed, $skip skipped of $i"; } 2>&1)
    row() { printf '  %-4s %-46s %3ss  %s\n' "$1" "$2" "$3" "$4"; }
    want=$(row FAIL "$py_cmd" 11 'exit 7'
           printf '        %s\n' 'planted FAIL in python' 'an ERROR line' 'a RED line' 'an ABORT line' 'a BROKEN line' '# a FAIL line that begins with a hash'
           echo "        (full output: python3 $py_cmd)"
           row FAIL "$sh_cmd" 12 'exit 7'
           echo '        planted-FAIL'
           echo "        (full output: bash $sh_cmd)"
           row PASS "$stub 0 ok" 13 'ok'
           row FAIL "$other_cmd" 14 'portability gate exited 7'
           echo '        portability:-FAIL:-planted'
           echo "        (full output: bash $other_cmd)"
           row FAIL "$lost_cmd" 0 'no result: the lane died'
           echo "        (full output: bash $lost_cmd)"
           row SKIP "$stub 99 must-not-run" 16 'no eigenscript binary (run make to include this gate)'
           row PASS "$stub 0 bin-ok" 17 'bin-ok'
           echo 'counted: 2 passed, 4 failed, 1 skipped of 7')
    if [ "$report" = "$want" ]; then
        echo 'PASS: failure hints name Python and shell commands'
    else
        echo "FAIL: failure hints: the report of seven rows was:"; printf '%s\n' "$report" | sed 's/^/    | /'
        echo "    wanted:"; printf '%s\n' "$want" | sed 's/^/    | /'
        fail=$((fail + 1))
    fi
    # A failing row whose log starts with six `#` lines that hold no red word, then its red
    # line: the same report_rows must show the red line, so `#` lines cannot crowd it out.
    crowd=$(OUT="$OUT/crowd"; mkdir -p "$OUT" || exit 1
            crowd_stub="$OUT/crowded.py"
            printf '%s\n' 'import sys' 'for n in range(6):' '    print("# comment %d" % n)' \
                'print("the real FAIL line")' 'sys.exit(3)' > "$crowd_stub"
            run_gate 0 run "$crowd_stub"
            GATES="run|$crowd_stub"; report_rows 2>&1)
    if printf '%s\n' "$crowd" | grep -Fxq '        the real FAIL line' \
       && [ "$(printf '%s\n' "$crowd" | grep -c '^        # comment')" -eq 0 ]; then
        echo 'PASS: comment lines cannot crowd real failures from the report'
    else
        echo "FAIL: comment lines crowded the report of a failing row:"; printf '%s\n' "$crowd" | sed 's/^/    | /'
        fail=$((fail + 1))
    fi
    echo "precheck-selftest: $((12 - fail))/12 passed, $fail failed"
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
run|tools/workflow_injection_check.py
run|tools/workflow_image_digest_check.py
run|tools/release_main_guard_2217_test.py --selftest
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
run|tools/tape_kinds_check.sh
run|tools/vendor_llhttp_check.sh
run|tools/lsp_builtin_index_check.sh
run|tools/section_fragments_check.sh --no-new-inline $BASE
run|tools/changelog_fragments.sh check $BASE
portability|tools/portability_parse_check.sh
selftest|tools/selftests.sh --changed $BASE
run|tools/make381_number_sign_check.py"

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
# CI owns this row separately: the PR's or merge group's base SHA, the pushed range on
# main, or origin/main on a workflow_dispatch (which carries no base).
i=0
while IFS='|' read -r class cmd; do
    if [ "$class" = selftest ]; then
        if [ "${PRECHECK_SELFTESTS:-1}" = 0 ]; then
            echo "SKIP|0|CI runs the driver separately (event base SHA, or origin/main on a dispatch)" > "$OUT/$i.st"
        else
            run_gate "$i" "$class" $cmd
            cat "$OUT/$i.log"
        fi
    fi
    i=$((i + 1))
done <<< "$GATES"

report_rows
# Every row must have produced a verdict (a gate that ran nothing is not a pass).
[ $((pass + fail + skip)) -eq "$i" ] && [ "$i" -gt 0 ] || { echo "precheck: ABORTED: $((pass + fail + skip)) results for $i gates"; exit 2; }
echo "precheck: $pass passed, $fail failed, $skip skipped in $(( $(date +%s) - T0 ))s"
[ "$fail" -eq 0 ]
