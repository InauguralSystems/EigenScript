#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."

sources="lib/functional.eigs src/builtins.c"
check_args="--allow-undocumented tools/api_docs_legacy_allowlist.txt
--check-region library docs/STDLIB.md
--check-region builtin docs/BUILTINS.md"
# shellcheck disable=SC2086 # intentional argument list
python3 tools/api_doc_ir.py $check_args $sources >/dev/null

if [ "${1:-}" = "--no-examples" ]; then
    echo "api-docs: reference is current (examples not requested)"
    exit 0
fi

eigs=${EIGS:-src/eigenscript}
[ -x "$eigs" ] || { echo "api-docs: $eigs is not executable" >&2; exit 1; }
# shellcheck disable=SC2086 # intentional argument list
python3 tools/api_doc_ir.py $check_args --run-examples "$eigs" $sources >/dev/null
echo "api-docs: reference is current and extracted examples pass"
