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
rc_expect() {
    local class=0
    printf '%s\n' "$3" | sed 's/^/    /'
    lsan_classify "$3" || class=$?
    [ "$class" -eq 1 ] && return 1
    [ "$class" -eq 0 ] && return 0
    [ "$2" -eq "$1" ]
}
# A run's standard error holds nothing, or a report that the classifier calls
# leak-only (rc_expect has printed it, so the section's rc_ok records it).
# Anything else on standard error fails the row.
quiet_or_leak_only() {
    [ -s "$1" ] || return 0
    local class=0
    lsan_classify "$(cat "$1")" || class=$?
    [ "$class" -eq 0 ]
}

# Clean control: the same kind of test file without the failing assertion.
set +e
"$EIGS" --test "$TMP/pass" >"$TMP/pass.out" 2>"$TMP/pass.err"
pass_rc=$?
set -e
pass_output=$(cat "$TMP/pass.out" "$TMP/pass.err")
rc_expect 0 "$pass_rc" "$pass_output" || fail "all-passing control exited $pass_rc or emitted a sanitizer diagnostic"
quiet_or_leak_only "$TMP/pass.err" || fail "all-passing control wrote to standard error"
[ "$(tail -n 1 "$TMP/pass.out")" = "Files: 1 | Passed: 1 | Failed: 0" ] ||
    fail "all-passing control ended with an unexpected line"
ok "all-passing run ends with its summary and exits 0"

set +e
"$EIGS" --test "$TMP/fail" >"$TMP/fail.out" 2>&1
fail_rc=$?
set -e
fail_output=$(cat "$TMP/fail.out")
rc_expect 1 "$fail_rc" "$fail_output" || fail "failing run exited $fail_rc or emitted a sanitizer diagnostic"
# The summary is the LAST thing the run prints (#2197), with both streams in
# the order they were written (the failing file's own trace comes before it).
# The one thing that may follow it is a report the classifier calls leak-only,
# which a sanitizer build writes at exit; rc_expect has printed it.
fail_tail=$(sed -n '/^Files: 1 | Passed: 0 | Failed: 1$/,$p' "$TMP/fail.out")
[ -n "$fail_tail" ] || fail "failing run did not print its summary"
fail_after=$(printf '%s\n' "$fail_tail" | tail -n +2)
if [ -n "$fail_after" ]; then
    fail_after_class=0
    lsan_classify "$fail_after" || fail_after_class=$?
    [ "$fail_after_class" -eq 0 ] || fail "failing run printed something after its summary"
fi
! grep -F 'lib/test_runner.eigs' "$TMP/fail.out" >/dev/null || fail "failing run printed a runner trace"
! grep -F 'test file(s) failed' "$TMP/fail.out" >/dev/null || fail "failing run raised a runner assertion"
ok "failing run ends with its summary and exits 1 without a runner trace"

set +e
"$EIGS" --test --json "$TMP/fail" >"$TMP/fail.json" 2>"$TMP/fail-json.err"
json_rc=$?
set -e
json_output=$(cat "$TMP/fail.json" "$TMP/fail-json.err")
rc_expect 1 "$json_rc" "$json_output" || fail "failing JSON run exited $json_rc or emitted a sanitizer diagnostic"
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
