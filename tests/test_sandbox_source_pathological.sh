#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EIGS=${EIGS:-"$ROOT/src/eigenscript"}
TMP=${TMPDIR:-/tmp}/eigs-sandbox-source-$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"

python3 - "$TMP/cases.eigs" <<'PY'
import json, sys
flat = "".join(f"x is {i}\n" for i in range(30000))
deep = "x is " + "(" * 5000 + "1" + ")" * 5000 + "\n"
with open(sys.argv[1], "w", encoding="utf-8") as f:
    f.write('a is sandbox_run of [%s, 1000, 2097152, 10000]\n' % json.dumps(flat))
    f.write('print of (a.ok == false and a.error.kind == "sandbox")\n')
    f.write('b is sandbox_run of [%s, 1000, 4194304, 10000]\n' % json.dumps(deep))
    f.write('print of (b.ok == false and (b.error.kind == "parse" or b.error.kind == "sandbox"))\n')
PY

out=$($EIGS "$TMP/cases.eigs" 2>&1)
[ "$out" = "true
true" ] || { printf '%s\n' "$out"; exit 1; }
printf '%s\n' "PASS: pathological sandbox source"
