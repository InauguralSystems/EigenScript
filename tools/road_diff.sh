#!/usr/bin/env bash
# The Python driver owns enumeration, bounded subprocesses, and fault plants.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec python3 "$ROOT/tools/road_diff.py" "$@"
