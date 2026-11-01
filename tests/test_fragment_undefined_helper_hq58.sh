#!/bin/bash
# hq#58: a fragment that calls a command which does not exist must go red.
#
# [1a7] called `run_test`, defined nowhere. In statement position bash printed
# "run_test: command not found", set $? = 127 and ran the next line, so the 19
# sandbox asserts never ran in any lane while the section printed PASS. Two
# gates had to agree for that to stay green, and this file plants the defect
# through each REAL gate rather than a copy of its logic:
#
#   runner     tests/run_all_tests.sh's command_not_found_handle + the section
#              close tally. A scratch tree holds a planted fragment and the
#              real runner runs it in section-plan mode (EIGS_SUITE_SECTIONS).
#   enrolment  tools/enrolment_check.sh, which counted [1a7]'s program as
#              invoked because tools/enrolment_edges.py trusted `run_test` by
#              name. A scratch repository holds planted fragment lines.
#
# Each gate is also run with its new check gutted, and the plants must come
# back green there: that is what shows the check, not something else, is the
# witness. Usage: bash tests/test_fragment_undefined_helper_hq58.sh --selftest
# (tools/selftests.txt). Exit 0 all cases passed, 1 a case failed, 2 the
# harness could not run.
set -u
[ "${1:-}" = "--selftest" ] || { echo "usage: $0 --selftest"; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The hook is bash 4+. CI runs this row on Linux; under bash 3.2 there is no
# hook to calibrate, and saying so is an instrument error, not a pass.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "INSTRUMENT ERROR: bash ${BASH_VERSION} has no command_not_found_handle (needs bash >= 4)"; exit 2
fi
[ -x "$ROOT/src/eigenscript" ] || { echo "INSTRUMENT ERROR: build src/eigenscript first"; exit 2; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs_hq58.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); printf '%s\n' "${2:-}" | tail -15 | sed 's/^/      /'; }

# ---- enrolment gate (runs in the background while the runner cases run) ----
enrolment_cases() {
    local ST="$WORK/enrol" out rc
    mkdir -p "$ST/tests/sections" "$ST/tools" "$ST/.github" || return 2
    (cd "$ROOT" && cp tests/*.sh tests/*.py tests/*.eigs tests/enrolment_exemptions.txt "$ST/tests/" \
        && cp tests/sections/*.sh "$ST/tests/sections/" && cp tools/*.sh tools/*.py tools/selftests.txt "$ST/tools/" \
        && cp -R .github/. "$ST/.github/" && cp Makefile "$ST/") || return 2
    [ -d "$ROOT/bench" ] && cp -R "$ROOT/bench" "$ST/bench"
    printf 'test_summary of null\n' > "$ST/tests/test_zz_hq58_undefined.eigs"
    printf 'test_summary of null\n' > "$ST/tests/test_zz_hq58_ungoverned.eigs"
    printf 'test_summary of null\n' > "$ST/tests/test_zz_hq58_outofscope.eigs"
    printf 'test_summary of null\n' > "$ST/tests/test_zz_hq58_defined.eigs"
    # Plant 1: the [1a7] shape. Plant 2: a trusted-table helper whose only
    # definition was removed. Plant 3: run_bounded IS defined, but only inside
    # unrelated tests/*_mt.sh scripts, never in the runner's shell.
    # Control: suite_program_run is defined in the runner's shell and enrols.
    sed -i.bak 's/^gfx_headless_run() {/gfx_headless_run_removed() {/' "$ST/tests/gfx_headless.sh" && rm "$ST/tests/gfx_headless.sh.bak"
    cat > "$ST/tests/sections/zz-hq58-plant.sh" <<'EOF'
echo "[zzhq58] planted launch helpers (hq#58)"
run_test "planted" "$EIGS" "$TESTS_DIR/test_zz_hq58_undefined.eigs"
gfx_headless_run 30 "$EIGS" "$TESTS_DIR/test_zz_hq58_ungoverned.eigs"
run_bounded "$WORK/out" "$EIGS" "$TESTS_DIR/test_zz_hq58_outofscope.eigs"
suite_program_run test_zz_hq58_defined.eigs "$EIGS" "$TESTS_DIR/test_zz_hq58_defined.eigs"
EOF
    (cd "$ST" && git init -q && git add .) || return 2
    out=$(ENROL_ROOT="$ST" bash "$ROOT/tools/enrolment_check.sh" 2>&1); rc=$?
    printf '%s\n' "$out" > "$WORK/enrol.real"; echo "$rc" > "$WORK/enrol.real.rc"
    # Gutted: the defined-helper rule removed from a copy of the edge deriver.
    sed -i.bak '/if words\[0\] in metadata and words\[0\] not in defined:/{N;d;}' "$ST/tools/enrolment_edges.py" && rm "$ST/tools/enrolment_edges.py.bak"
    sed -i.bak 's/"gfx_headless_run": 1,/"gfx_headless_run": 1, "run_test": 1,/' "$ST/tools/enrolment_edges.py" && rm "$ST/tools/enrolment_edges.py.bak"
    out=$(ENROL_ROOT="$ST" bash "$ROOT/tools/enrolment_check.sh" 2>&1); rc=$?
    printf '%s\n' "$out" > "$WORK/enrol.gutted"; echo "$rc" > "$WORK/enrol.gutted.rc"
}
enrolment_cases > "$WORK/enrol.setup" 2>&1 &
ENROL_PID=$!

# ---- runner gate -------------------------------------------------------------
# Two runners over one scratch tree whose only fragment is the plant:
#   full   the real runner with its inline sections elided: the real preamble
#          (the hook, the section close) and everything from the fragment
#          loop on (the `. fragment` loop, [99p], the epilogue), verbatim. This
#          is the sourcing path `bash run_all_tests.sh` takes, and it is fast.
#   plan   the real runner untouched, in section-plan mode, the path every
#          sharded and changed-sections lane takes (fragments are inlined).
T="$WORK/tree"
mkdir -p "$T" && cp -R "$ROOT/tests" "$ROOT/tools" "$T/" && cp -R "$ROOT/.github" "$T/.github" \
    && ln -s "$ROOT/src" "$T/src" && ln -s "$ROOT/lib" "$T/lib" || { echo "INSTRUMENT ERROR: cannot build scratch tree"; exit 2; }
# The real tree's lock is not ours to take; the scratch tree has its own.
unset EIGS_TREE_LOCK_HELD
rm -f "$T/tests/sections/"*.sh
RUNNER="$ROOT/tests/run_all_tests.sh"
first=$(grep -n '^echo "\[' "$RUNNER" | head -1 | cut -d: -f1)
seam=$(grep -n '^# EIGS_SECTION_FRAGMENTS$' "$RUNNER" | cut -d: -f1)
if [ -z "$first" ] || [ -z "$seam" ] || [ "$first" -ge "$seam" ]; then
    echo "INSTRUMENT ERROR: cannot find the first section ($first) or the fragment seam ($seam) in $RUNNER"; exit 2
fi
{ head -n $((first - 1)) "$RUNNER"; tail -n +"$seam" "$RUNNER"; } > "$T/tests/run_full.sh"
FRAG="$T/tests/sections/zz-hq58-plant.sh"
plant() {   # plant <statement or empty>
    {
        echo 'echo "[zzhq58] undefined-command plant (hq#58)"'
        [ -n "$1" ] && printf '%s\n' "$1"
        echo 'TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); echo "  PASS: the check after the plant"'
        echo 'echo ""'
    } > "$FRAG"
}
run_full() { OUT=$(cd "$T/tests" && bash run_full.sh 2>&1); RC=$?; }
run_plan() { OUT=$(cd "$T/tests" && EIGS_SUITE_SECTIONS='zzhq58' bash run_all_tests.sh 2>&1); RC=$?; }
RUN_1A7='run_test "sandbox source budgets" "$EIGS" "$TESTS_DIR/test_sandbox_source_budget.eigs"'
expect_red() {   # expect_red <label> <command name>
    if [ "$RC" -eq 1 ] && grep -q "FAIL: \[zzhq58\] ran a command that does not exist: $2" <<< "$OUT"; then
        ok "$1"
    else
        bad "$1 (rc=$RC, no FAIL naming $2)" "$OUT"
    fi
}

plant ""
run_full
if [ "$RC" -eq 0 ] && grep -q 'RESULTS: [0-9]*/[0-9]* passed, 0 failed' <<< "$OUT" && grep -q 'PASS: the check after the plant' <<< "$OUT"; then
    ok "runner control: an unplanted fragment is green"
else
    bad "runner control: an unplanted fragment is not green (rc=$RC) -- harness bug, not a verdict" "$OUT"
fi

plant "$RUN_1A7"
run_full
expect_red "runner plant (sourced): the [1a7] statement (run_test) fails its section" run_test
run_plan
expect_red "runner plant (section plan): the [1a7] statement (run_test) fails its section" run_test

plant 'planted_out=$(undefined_helper_hq58 "x" 2>&1)'
run_full
expect_red "runner plant: an undefined command inside a captured substitution fails its section" undefined_helper_hq58

plant 'if undefined_probe_hq58; then echo "  PASS: never"; fi'
run_full
expect_red "runner plant: an undefined command in condition position fails its section too" undefined_probe_hq58

# Gutted: the same [1a7] plant under a runner whose hook was deleted must be
# green again, or the plant is not measuring the hook.
plant "$RUN_1A7"
sed -i.bak '/^command_not_found_handle() {$/,/^}$/d' "$T/tests/run_full.sh" && rm "$T/tests/run_full.sh.bak"
if grep -q '^command_not_found_handle()' "$T/tests/run_full.sh"; then
    bad "runner gutted: could not remove the hook from the scratch runner -- harness bug" ""
else
    run_full
    if [ "$RC" -eq 0 ] && grep -q 'run_test: command not found' <<< "$OUT"; then
        ok "runner gutted: without the hook the same plant is green (the hook is the witness)"
    else
        bad "runner gutted: without the hook the plant was not green (rc=$RC) -- the plant is not measuring the hook" "$OUT"
    fi
fi

# ---- enrolment verdicts --------------------------------------------------------
wait "$ENROL_PID"; enrol_setup_rc=$?
if [ "$enrol_setup_rc" -ne 0 ] || [ ! -s "$WORK/enrol.real.rc" ] || [ ! -s "$WORK/enrol.gutted.rc" ]; then
    echo "INSTRUMENT ERROR: enrolment scratch repository (rc=$enrol_setup_rc)"; cat "$WORK/enrol.setup"; exit 2
fi
REAL=$(cat "$WORK/enrol.real"); REAL_RC=$(cat "$WORK/enrol.real.rc")
GUT=$(cat "$WORK/enrol.gutted"); GUT_RC=$(cat "$WORK/enrol.gutted.rc")
for f in undefined ungoverned outofscope; do
    case $f in
        undefined) what="a helper defined nowhere (run_test, the [1a7] shape)" ;;
        ungoverned) what="a trusted helper whose definition was removed (gfx_headless_run)" ;;
        outofscope) what="a helper defined only in unrelated scripts (run_bounded)" ;;
    esac
    if [ "$REAL_RC" -eq 1 ] && grep -qF "tests/test_zz_hq58_$f.eigs has no suite invocation" <<< "$REAL"; then
        ok "enrolment plant: $what does not enrol its program"
    else
        bad "enrolment plant: $what enrolled its program (rc=$REAL_RC)" "$REAL"
    fi
    if grep -qF "tests/test_zz_hq58_$f.eigs has no suite invocation" <<< "$GUT"; then
        bad "enrolment gutted: $f still red with the defined-helper rule removed -- the plant is not measuring the rule" "$GUT"
    else
        ok "enrolment gutted: without the defined-helper rule, $f enrols again (the rule is the witness)"
    fi
done
if grep -qF "tests/test_zz_hq58_defined.eigs" <<< "$REAL"; then
    bad "enrolment control: a helper defined in the runner's shell (suite_program_run) no longer enrols" "$REAL"
else
    ok "enrolment control: a helper defined in the runner's shell (suite_program_run) still enrols"
fi

echo "hq58 selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
