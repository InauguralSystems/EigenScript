#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOOL=${1:-$ROOT/tools/strict_differential.sh}
out=$(bash "$TOOL" --renderer-probe-selftest 2>&1)
rc=$?
printf '%s\n' "$out"
[ "$rc" -eq 0 ] &&
    grep -qx 'RENDERER PROBE SELFTEST: 5 passed, 0 failed, 5 declared' <<< "$out"
