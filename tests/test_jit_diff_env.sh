#!/usr/bin/env bash
# Regression for #1395: the suite and jit_diff must consume one environment
# policy, and a fail-soft program must reach its final marker through it.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
export EIGS_TEST_DIR="$TESTS_DIR"
. "$TESTS_DIR/suite_program_env.sh" || exit 1

expected='test_buffer_nonfinite_read.eigs
test_builtin_contracts.eigs
test_builtin_indirect.eigs
test_file_io.eigs
test_file_rename.eigs
test_json_hard.eigs
test_numeric_guard.eigs
test_stdlib_fixes.eigs
test_stream_io.eigs
test_tensor_buffer_ops.eigs'
actual=$(awk '$0 !~ /^[[:space:]]*#/ && NF { print $1 }' "$TESTS_DIR/suite_program_env.txt" | sort)
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
echo "PASS: jit_diff and the suite share 10 per-program environments; fail-soft program reached its final marker"
