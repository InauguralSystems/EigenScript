#!/usr/bin/env bash

echo "PLAN: 3"
set -eu

EIGS=${EIGS:-${EIGENSCRIPT:-$(cd "$(dirname "$0")/.." && pwd)/src/eigenscript}}
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
. "$TESTS_DIR/lsan_classify.sh" || exit 1
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/pass" "$TMP/fail"
printf 'assert of [true, "ok"]\n' > "$TMP/pass/test_ok.eigs"
printf 'assert of [false, "plant: expected failure"]\n' > "$TMP/fail/test_bad.eigs"

fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "PASS: $*"; }
# clean_exit WANT RC OUTPUT: the exit status is WANT and the output holds no
# sanitizer report of any kind. These rows tolerate no report, a leak-only one
# included, as the suite's other child scripts do (.claude/rules/test-suite.md:
# the sites that call lsan_classify and require "none"). The suite's ledger of
# tolerated leak reports is filled by the runner's own functions; a child
# script cannot add to it, so it does not tolerate what it cannot record.
clean_exit() {
    local class=0
    lsan_classify "$3" || class=$?
    [ "$class" -eq 2 ] && [ "$2" -eq "$1" ]
}
show() { printf '%s\n' "$1" | sed 's/^/    /'; }

# Clean control: the same kind of test file without the failing assertion.
set +e
"$EIGS" --test "$TMP/pass" >"$TMP/pass.out" 2>"$TMP/pass.err"
pass_rc=$?
set -e
pass_output=$(cat "$TMP/pass.out" "$TMP/pass.err")
clean_exit 0 "$pass_rc" "$pass_output" || { show "$pass_output"; fail "all-passing control exited $pass_rc or printed a sanitizer report"; }
[ ! -s "$TMP/pass.err" ] || { show "$pass_output"; fail "all-passing control wrote to standard error"; }
[ "$(tail -n 1 "$TMP/pass.out")" = "Files: 1 | Passed: 1 | Failed: 0" ] ||
    fail "all-passing control ended with an unexpected line"
ok "all-passing run ends with its summary and exits 0"

set +e
"$EIGS" --test "$TMP/fail" >"$TMP/fail.out" 2>&1
fail_rc=$?
set -e
fail_output=$(cat "$TMP/fail.out")
clean_exit 1 "$fail_rc" "$fail_output" || { show "$fail_output"; fail "failing run exited $fail_rc or printed a sanitizer report"; }
# The summary is the LAST line the run prints (#2197), with both streams in
# the order they were written: the failing file's own trace comes before it.
[ "$(tail -n 1 "$TMP/fail.out")" = "Files: 1 | Passed: 0 | Failed: 1" ] ||
    { show "$fail_output"; fail "failing run did not end with its summary"; }
! grep -F 'lib/test_runner.eigs' "$TMP/fail.out" >/dev/null || fail "failing run printed a runner trace"
! grep -F 'test file(s) failed' "$TMP/fail.out" >/dev/null || fail "failing run raised a runner assertion"
ok "failing run ends with its summary and exits 1 without a runner trace"

set +e
"$EIGS" --test --json "$TMP/fail" >"$TMP/fail.json" 2>"$TMP/fail-json.err"
json_rc=$?
set -e
json_output=$(cat "$TMP/fail.json" "$TMP/fail-json.err")
clean_exit 1 "$json_rc" "$json_output" || { show "$json_output"; fail "failing JSON run exited $json_rc or printed a sanitizer report"; }
! grep -F 'lib/test_runner.eigs' "$TMP/fail-json.err" >/dev/null || fail "failing JSON run printed a runner trace"
! grep -F 'test file(s) failed' "$TMP/fail-json.err" >/dev/null || fail "failing JSON run raised a runner assertion"
python3 - "$TMP/fail.json" <<'PY' || fail "JSON stdout was not exactly one document"
import json
import pathlib
import sys

payload = pathlib.Path(sys.argv[1]).read_text()
decoder = json.JSONDecoder()
value, end = decoder.raw_decode(payload)
if payload[end:].strip():
    raise SystemExit("content follows JSON document")
if value["failed"] != 1:
    raise SystemExit("JSON did not report one failed file")
PY
[ "$(tail -n 1 "$TMP/fail.json")" = "$(cat "$TMP/fail.json")" ] ||
    fail "JSON document was not the last and only output line"
ok "failing JSON run emits one document and exits 1 without trailing output"
