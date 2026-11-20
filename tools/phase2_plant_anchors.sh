#!/usr/bin/env bash
# Fast, product-triggered entry point for phase2_plants.sh's exact-once anchors.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -ne 1 ] || [ "$1" != --selftest ]; then
    echo "phase2-plant-anchors: FAIL: usage: $0 --selftest"
    exit 2
fi
exec bash "$ROOT/tools/phase2_plants.sh" --anchors
