#!/bin/bash
set -u

if [ "${1:-}" != "--selftest" ]; then
    echo "usage: $0 --selftest" >&2
    exit 2
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BINARY=${EIGENSCRIPT:-$ROOT/build/release/eigenscript}
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/run-bench-selftest.XXXXXX") || exit 1
cp "$ROOT/bench/run_bench.sh" "$ROOT/bench/scalar_loop.eigs" "$SCRATCH/"

if ! EIGENSCRIPT="$BINARY" bash "$SCRATCH/run_bench.sh" >"$SCRATCH/control.out" 2>&1; then
    echo "SELFTEST FAILED: clean control did not pass"
    cat "$SCRATCH/control.out"
    exit 1
fi
if ! grep -q '^scalar_loop ' "$SCRATCH/control.out"; then
    echo "SELFTEST FAILED: clean control printed no scalar_loop row"
    exit 1
fi

{ echo 'throw of "planted failure"'; cat "$ROOT/bench/scalar_loop.eigs"; } >"$SCRATCH/planted.eigs"
mv "$SCRATCH/planted.eigs" "$SCRATCH/scalar_loop.eigs"
EIGENSCRIPT="$BINARY" bash "$SCRATCH/run_bench.sh" >"$SCRATCH/plant.out" 2>&1
rc=$?
if [ "$rc" -eq 0 ] || ! grep -q 'ERROR: workload scalar_loop failed' "$SCRATCH/plant.out"; then
    echo "SELFTEST FAILED: planted failure was not named and rejected"
    cat "$SCRATCH/plant.out"
    exit 1
fi
if grep -q '^scalar_loop ' "$SCRATCH/plant.out"; then
    echo "SELFTEST FAILED: planted workload received a result row"
    cat "$SCRATCH/plant.out"
    exit 1
fi
echo "SELFTEST OK: clean control passed; throwing workload was named, rejected, and received no median"
