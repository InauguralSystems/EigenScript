#!/bin/bash
# Mutation-test the final suite tally against the three faults documented in
# #1354.  Execute the production verdict block with tiny synthetic counters so
# this test stays fast and tests the same code used by full and planned runs.
set -u

[ "${1:-}" = "--selftest" ] || { echo 'usage: tests/test_runner_tally.sh --selftest' >&2; exit 2; }

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RUNNER="$ROOT/tests/run_all_tests.sh"
TMP=$(mktemp "${TMPDIR:-/tmp}/eigs-tally.XXXXXX") || exit 2
trap 'rm -f "$TMP"' EXIT

extract_verdict() {
    sed -n '/^# A run that asserted NOTHING/,${p;}' "$RUNNER"
}

extract_section_skip() {
    sed -n '/^section_skip() {$/,/^}$/p' "$RUNNER"
}

run_case() { # name pass fail total skipped expected_rc expected_text [setup [section_skip_definition]]
    name=$1; pass=$2; fail=$3; total=$4; skipped=$5; want_rc=$6; want=$7
    setup=${8:-:}
    section_skip_definition=${9:-}
    {
        printf '%s\n' '#!/bin/bash' 'check_binary_fingerprint() { :; }' '__eigs_section_close() { :; }'
        if [ -n "$section_skip_definition" ]; then
            printf '%s\n' "$section_skip_definition"
        else
            extract_section_skip
        fi
        printf 'PASS=%s FAIL=%s TOTAL=%s SKIPPED=%s LEAKED=0\n' "$pass" "$fail" "$total" "$skipped"
        printf '%s\n' "$setup"
        extract_verdict
    } > "$TMP"
    out=$(bash "$TMP" 2>&1); rc=$?
    if [ "$rc" -eq "$want_rc" ] && grep -qF "$want" <<< "$out"; then
        echo "  PASS: $name"
        return 0
    fi
    echo "  FAIL: $name (rc=$rc, wanted $want_rc; missing: $want)"
    printf '%s\n' "$out" | sed 's/^/      /'
    return 1
}

bad=0
run_case 'double-counted PASS is rejected' 2 0 1 0 1 'PASS + FAIL != TOTAL' || bad=$((bad + 1))
# Plant the exact historical fault rather than merely calling the healthy
# helper.  The mutant's final PASS/FAIL arithmetic is still balanced, so only
# the skipped-verdict assertion below can kill it.  Treat run_case's failure as
# success here: it proves this mutation makes the tally self-test red.
mutation_out=$(run_case 'vanished verdict is rejected' 1 0 1 0 0 \
    'RESULTS: 1/1 passed, 0 failed, 1 skipped' \
    "section_skip 'fixture unavailable'" 'section_skip() { :; }' 2>&1)
mutation_rc=$?
if [ "$mutation_rc" -ne 0 ] && grep -qF 'missing: RESULTS: 1/1 passed, 0 failed, 1 skipped' <<< "$mutation_out"; then
    echo '  PASS: vanished verdict mutation is rejected'
else
    echo '  FAIL: vanished verdict mutation survived'
    printf '%s\n' "$mutation_out" | sed 's/^/      /'
    bad=$((bad + 1))
fi
run_case 'skip without TOTAL rollback is rejected' 0 0 1 1 1 'PASS + FAIL != TOTAL' || bad=$((bad + 1))
run_case 'section skip stays outside TOTAL' 1 0 1 1 0 'RESULTS: 1/1 passed, 0 failed, 1 skipped' || bad=$((bad + 1))

if [ "$bad" -ne 0 ]; then
    echo "RUNNER_TALLY_SELFTEST: $bad of 4 cases failed"
    exit 1
fi
echo 'RUNNER_TALLY_SELFTEST: 4 passed, 0 failed'
