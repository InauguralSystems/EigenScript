#!/usr/bin/env bash
# Portable entry point for the #2018 C/Lean differential driver.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd) || exit 2
exec python3 "$ROOT/tools/ref_diff.py" "$@"
