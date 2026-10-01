#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.." || exit 2
exec python3 tools/spec_authority_check.py "$@"
