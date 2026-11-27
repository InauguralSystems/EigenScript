#!/bin/bash
# #2525: a set-but-empty EIGS_SUITE_SECTIONS is refused, never read as unset.
#
# A caller whose label lookup came back empty ran `EIGS_SUITE_SECTIONS="" bash
# run_all_tests.sh` meaning one section and got the whole ~45-minute suite.
# tests/suite_plan.sh (sourced by the runner's preamble) now refuses an empty
# or whitespace-only value with one line naming the variable, rc 1.
#
# The cases run the REAL runner over a scratch tree whose only fragment is a
# one-check plant, so a "whole suite" here is seconds, not 45 minutes:
#   full   the runner with its inline sections elided (preamble + fragment loop
#          + epilogue, verbatim): the path a whole-suite run takes. Empty and
#          whitespace values are run here, so without the guard they run this
#          small suite and go green -- which is the red this test reports.
#   plan   the runner untouched, in section-plan mode, for a real label.
# Usage: bash tests/test_suite_sections_empty_2525.sh --selftest
# (tools/selftests.txt). Exit 0 all cases passed, 1 a case failed, 2 the
# harness could not run.
set -u
[ "${1:-}" = "--selftest" ] || { echo "usage: $0 --selftest"; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -x "$ROOT/src/eigenscript" ] || { echo "INSTRUMENT ERROR: build src/eigenscript first"; exit 2; }
WORK=$(mktemp -d "$(dirname "$ROOT")/eigs_2525.XXXXXX") || { echo "INSTRUMENT ERROR: cannot make a scratch directory"; exit 2; }
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); printf '%s\n' "${2:-}" | tail -15 | sed 's/^/      /'; }

T="$WORK/tree"
mkdir -p "$T" && cp -R "$ROOT/tests" "$ROOT/tools" "$T/" && cp -R "$ROOT/.github" "$T/.github" \
    && ln -s "$ROOT/src" "$T/src" && ln -s "$ROOT/lib" "$T/lib" || { echo "INSTRUMENT ERROR: cannot build scratch tree"; exit 2; }
unset EIGS_TREE_LOCK_HELD EIGS_PLAN_ACTIVE EIGS_SUITE_SHARD EIGS_SUITE_CHANGED EIGS_SUITE_SECTIONS
rm -f "$T/tests/sections/"*.sh
RUNNER="$ROOT/tests/run_all_tests.sh"
first=$(grep -n '^echo "\[' "$RUNNER" | head -1 | cut -d: -f1)
seam=$(grep -n '^# EIGS_SECTION_FRAGMENTS$' "$RUNNER" | cut -d: -f1)
if [ -z "$first" ] || [ -z "$seam" ] || [ "$first" -ge "$seam" ]; then
    echo "INSTRUMENT ERROR: cannot find the first section ($first) or the fragment seam ($seam) in $RUNNER"; exit 2
fi
{ head -n $((first - 1)) "$RUNNER"; tail -n +"$seam" "$RUNNER"; } > "$T/tests/run_full.sh"
cat > "$T/tests/sections/zz-2525-plant.sh" <<'FRAG'
echo "[zz2525] the one planted check (#2525)"
TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); echo "  PASS: zz2525 planted check ran"
echo ""
FRAG
MSG='ERROR: EIGS_SUITE_SECTIONS is set but names no section -- unset it to run the whole suite (#2525)'

refused() {   # refused <label> <value>
    local out rc
    out=$(cd "$T/tests" && EIGS_SUITE_SECTIONS="$2" bash run_full.sh 2>&1); rc=$?
    if [ "$rc" -eq 1 ] && grep -qxF "$MSG" <<< "$out" && ! grep -q 'zz2525 planted check ran' <<< "$out"; then
        ok "$1 is refused with one line naming the variable, rc 1, nothing run"
    else
        bad "$1 was not refused (rc=$rc)" "$out"
    fi
}
refused "EIGS_SUITE_SECTIONS=''" ""
refused "EIGS_SUITE_SECTIONS of spaces" "   "
refused "EIGS_SUITE_SECTIONS of a tab and a newline" $'\t\n'

# Unset is still the whole suite: here, the one planted fragment, green.
out=$(cd "$T/tests" && bash run_full.sh 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q 'zz2525 planted check ran' <<< "$out" && grep -q 'RESULTS: [0-9]*/[0-9]* passed, 0 failed' <<< "$out" \
   && ! grep -qF "$MSG" <<< "$out"; then
    ok "unset EIGS_SUITE_SECTIONS still runs the whole suite"
else
    bad "unset EIGS_SUITE_SECTIONS did not run the whole suite (rc=$rc)" "$out"
fi

# A real label still runs that section through the planner.
out=$(cd "$T/tests" && EIGS_SUITE_SECTIONS='zz2525' bash run_all_tests.sh 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q 'zz2525 planted check ran' <<< "$out" && ! grep -qF "$MSG" <<< "$out"; then
    ok "EIGS_SUITE_SECTIONS=zz2525 runs that section"
else
    bad "EIGS_SUITE_SECTIONS=zz2525 did not run its section (rc=$rc)" "$out"
fi

echo "2525 selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
