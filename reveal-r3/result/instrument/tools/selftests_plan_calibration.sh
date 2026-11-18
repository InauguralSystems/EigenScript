#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 2
case "${1:-}" in
    --selftest) [ $# -eq 1 ] || { echo "usage: $0 --selftest" >&2; exit 2; } ;;
    *) echo "usage: $0 --selftest" >&2; exit 2 ;;
esac
exec bash "$ROOT/tools/selftests.sh" --calibrate-plan
