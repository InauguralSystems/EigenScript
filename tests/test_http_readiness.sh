#!/bin/bash
# Real HTTP readiness/header oracle (#1128/#1129). Works from src/ or repo root.
# Python owns subprocesses in try/finally, curl captures headers/body separately.
set -eu
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$TESTS_DIR/../src"
exec python3 "$TESTS_DIR/http_readiness.py" "$@"
