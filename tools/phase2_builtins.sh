#!/usr/bin/env bash
# The pre-registered bar owns the predicates and probe execution.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ "$#" -eq 2 ] || { echo "usage: tools/phase2_builtins.sh <tag-binary> <branch-binary>" >&2; exit 2; }
exec python3 "$ROOT/tests/phase2/builtins/make_table.py" --final --run "$1" "$2"
