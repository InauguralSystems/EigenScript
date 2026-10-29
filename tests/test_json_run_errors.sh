#!/bin/bash
# Ordinary-run machine-readable diagnostics (#2168).
set -u
TESTS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$TESTS_DIR/.." && pwd)
EIGS=${EIGS:-$ROOT/src/eigenscript}
TMP=${TMPDIR:-/tmp}/eigs-json-errors-$$
mkdir -p "$TMP" || exit 1
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

check_json() {
    name=$1 file=$2
    if "$EIGS" --json "$file" >"$TMP/out" 2>"$TMP/err"; then
        echo "  FAIL: $name (expected nonzero exit)"; return 1
    fi
    if [ -s "$TMP/out" ] && [ "$name" != runtime ]; then
        echo "  FAIL: $name (unexpected stdout)"; return 1
    fi
    if ! python3 -m json.tool "$TMP/err" >/dev/null; then
        echo "  FAIL: $name (stderr is not one JSON object)"; return 1
    fi
    echo "  PASS: $name"
}

cat >"$TMP/parse.eigs" <<'EIGS'
if true
    print of 1
EIGS
check_json "parse error JSON" "$TMP/parse.eigs" || exit 1
python3 - "$TMP/err" <<'PY' || exit 1
import json,sys
x=json.load(open(sys.argv[1]))
assert x == {"version":1,"code":"E002","kind":"parse","message":"expected ':', got newline","file":x["file"],"line":1,"column":8,"span":1,"frames":[]}
PY
echo "  PASS: parse error fields"

cat >"$TMP/runtime.eigs" <<'EIGS'
items is [1]
print of items[9]
EIGS
check_json "runtime error JSON" "$TMP/runtime.eigs" || exit 1
python3 - "$TMP/err" <<'PY' || exit 1
import json,sys
x=json.load(open(sys.argv[1])); assert x["kind"]=="runtime" and x["code"]=="index_range"
assert x["line"]==2 and x["column"]>0 and x["span"]>0 and x["frames"][-1]["function"]=="<module>"
PY
echo "  PASS: runtime error fields"

cat >"$TMP/frames.eigs" <<'EIGS'
define inner() as:
    throw of "boom"
define outer() as:
    inner of null
outer of null
EIGS
check_json "function error JSON" "$TMP/frames.eigs" || exit 1
python3 - "$TMP/err" <<'PY' || exit 1
import json,sys
x=json.load(open(sys.argv[1])); assert [f["function"] for f in x["frames"]]==["inner","outer","<module>"]
assert [f["line"] for f in x["frames"]]==[2,4,5]
PY
echo "  PASS: function frames"

python3 - "$TMP/bytes.eigs" <<'PY'
import sys
open(sys.argv[1],"wb").write(b'throw of "a quote: \\"; a newline: \\n; invalid: \xff"\n')
PY
check_json "escaped byte JSON" "$TMP/bytes.eigs" || exit 1
python3 - "$TMP/err" <<'PY' || exit 1
import json,sys
raw=open(sys.argv[1],"rb").read(); x=json.loads(raw)
assert x["message"] == 'a quote: "; a newline: \n; invalid: \ufffd'
assert b'\\"' in raw and b'\\n' in raw and b'\xef\xbf\xbd' in raw
PY
echo "  PASS: quote newline and invalid byte escaping"

if "$EIGS" --json -e 'exit of 23' >"$TMP/out" 2>"$TMP/err"; then rc=0; else rc=$?; fi
if [ "$rc" -ne 23 ] || [ -s "$TMP/err" ]; then
    echo "  FAIL: exit of N emitted a diagnostic or wrong status ($rc)"; exit 1
fi
echo "  PASS: exit of N is not an error"

# Runtime parsing used to restore fd 2 after the top-level parse, letting the
# nested parser's human diagnostics precede the VM's JSON diagnostic.
cat >"$TMP/eval-parse.eigs" <<'EIGS'
eval of "if true"
EIGS
check_json "eval parse error JSON" "$TMP/eval-parse.eigs" || exit 1

cat >"$TMP/nested-bad.eigs" <<'EIGS'
if true
EIGS
cat >"$TMP/load-parse.eigs" <<EIGS
load_file of "$TMP/nested-bad.eigs"
EIGS
check_json "load_file parse error JSON" "$TMP/load-parse.eigs" || exit 1

cat >"$TMP/json_bad_module_2168.eigs" <<'EIGS'
if true
EIGS
cat >"$TMP/import-parse.eigs" <<'EIGS'
import json_bad_module_2168
EIGS
if (cd "$TMP" && "$EIGS" --json import-parse.eigs >"$TMP/out" 2>"$TMP/err"); then
    echo "  FAIL: import parse error JSON (expected nonzero exit)"; exit 1
fi
if [ -s "$TMP/out" ] || ! python3 -m json.tool "$TMP/err" >/dev/null; then
    echo "  FAIL: import parse error JSON (stderr is not one JSON object)"; exit 1
fi
echo "  PASS: import parse error JSON"

cat >"$TMP/worker.eigs" <<'EIGS'
define fail_worker() as:
    throw of "worker boom"
spawn of fail_worker
EIGS
check_json "spawned function error JSON" "$TMP/worker.eigs" || exit 1

cat >"$TMP/worker-builtin.eigs" <<'EIGS'
spawn of [assert, [false, "builtin worker boom"]]
EIGS
check_json "spawned builtin error JSON" "$TMP/worker-builtin.eigs" || exit 1
