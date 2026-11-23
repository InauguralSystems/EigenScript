#!/usr/bin/env bash
# Regression for #1395: the suite and jit_diff must consume one environment
# policy, and a fail-soft program must reach its final marker through it.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
export EIGS_TEST_DIR="$TESTS_DIR"
. "$TESTS_DIR/suite_program_env.sh" || exit 1

expected='test_audio.eigs
test_gfx_argtypes.eigs
test_gfx_text.eigs
test_line_after_return.eigs
test_phase2_gfx_q7.eigs
test_sgd_update_refused_strict_2495.eigs
test_ui_containment_gfx.eigs'
actual=$(awk '$0 !~ /^[[:space:]]*#/ && NF { print $1 }' "$TESTS_DIR/suite_program_env.txt" | LC_ALL=C sort)
[ "$actual" = "$expected" ] || { echo "FAIL: suite environment population changed:"; printf '%s\n' "$actual"; exit 1; }

out=$(suite_program_run test_file_io.eigs "$TESTS_DIR/../src/eigenscript" "$TESTS_DIR/test_file_io.eigs" 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q 'All file_io tests passed' || {
    echo "FAIL: shared suite environment did not carry test_file_io.eigs past its first strict raise (rc=$rc)"
    printf '%s\n' "$out"
    exit 1
}
grep -q 'suite_program_env.*"$prog"' "$TESTS_DIR/../tools/jit_diff.sh" || {
    echo "FAIL: jit_diff does not derive its program environment from the suite lookup"
    exit 1
}
grep -q 'suite-env completed=\$n_suite_env' "$TESTS_DIR/../tools/jit_diff.sh" || {
    echo "FAIL: jit_diff does not report the suite-environment completion population"
    exit 1
}
echo "PASS: jit_diff and the suite share 19 per-program environments; fail-soft program reached its final marker"
