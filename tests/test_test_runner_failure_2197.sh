#!/usr/bin/env bash

echo "PLAN: 3"
set -eu

EIGS=${EIGS:-${EIGENSCRIPT:-$(cd "$(dirname "$0")/.." && pwd)/src/eigenscript}}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/pass" "$TMP/fail"
printf 'assert of [true, "ok"]\n' > "$TMP/pass/test_ok.eigs"
printf 'assert of [false, "plant: expected failure"]\n' > "$TMP/fail/test_bad.eigs"

fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "PASS: $*"; }

# Clean control: the same kind of test file without the failing assertion.
set +e
"$EIGS" --test "$TMP/pass" >"$TMP/pass.out" 2>"$TMP/pass.err"
pass_rc=$?
set -e
[ "$pass_rc" -eq 0 ] || fail "all-passing control exited $pass_rc, expected 0"
[ ! -s "$TMP/pass.err" ] || fail "all-passing control wrote stderr"
[ "$(tail -n 1 "$TMP/pass.out")" = "Files: 1 | Passed: 1 | Failed: 0" ] ||
    fail "all-passing control ended with an unexpected line"
ok "all-passing run ends with its summary and exits 0"

set +e
"$EIGS" --test "$TMP/fail" >"$TMP/fail.out" 2>&1
fail_rc=$?
set -e
[ "$fail_rc" -eq 1 ] || fail "failing run exited $fail_rc, expected 1"
[ "$(tail -n 1 "$TMP/fail.out")" = "Files: 1 | Passed: 0 | Failed: 1" ] ||
    fail "failing run did not end with its summary"
! grep -F 'lib/test_runner.eigs' "$TMP/fail.out" >/dev/null || fail "failing run printed a runner trace"
! grep -F 'test file(s) failed' "$TMP/fail.out" >/dev/null || fail "failing run raised a runner assertion"
ok "failing run ends with its summary and exits 1 without a runner trace"

set +e
"$EIGS" --test --json "$TMP/fail" >"$TMP/fail.json" 2>"$TMP/fail-json.err"
json_rc=$?
set -e
[ "$json_rc" -eq 1 ] || fail "failing JSON run exited $json_rc, expected 1"
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
