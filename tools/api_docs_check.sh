#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."

sources="lib/functional.eigs src/builtins.c"
python3 tools/api_doc_ir.py --format markdown --check docs/API_REFERENCE.md $sources

if [ "${1:-}" = "--no-examples" ]; then
    echo "api-docs: reference is current (examples not requested)"
    exit 0
fi

eigs=${EIGS:-src/eigenscript}
[ -x "$eigs" ] || { echo "api-docs: $eigs is not executable" >&2; exit 1; }
python3 tools/api_doc_ir.py --format markdown --check docs/API_REFERENCE.md \
    --run-examples "$eigs" $sources
echo "api-docs: reference is current and extracted examples pass"
