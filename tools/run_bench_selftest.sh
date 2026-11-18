#!/bin/bash
set -u

if [ "${1:-}" != "--selftest" ]; then
    echo "usage: $0 --selftest" >&2
    exit 2
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BINARY=${EIGENSCRIPT:-$ROOT/build/release/eigenscript}
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/run-bench-selftest.XXXXXX") || exit 1
trap 'rm -rf "$SCRATCH"' EXIT
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

# A workload that fails only on a later invocation: a stand-in for the binary
# that counts its runs and fails the third. A check that reads only the first
# exit status passes the plant above and fails here.
cp "$ROOT/bench/scalar_loop.eigs" "$SCRATCH/scalar_loop.eigs"
cat >"$SCRATCH/third-fails" <<STANDIN
#!/bin/bash
n=\$(cat "$SCRATCH/runs" 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" >"$SCRATCH/runs"
[ "\$n" -ne 3 ] || exit 7
exec "$BINARY" "\$@"
STANDIN
chmod +x "$SCRATCH/third-fails"
EIGENSCRIPT="$SCRATCH/third-fails" bash "$SCRATCH/run_bench.sh" >"$SCRATCH/later.out" 2>&1
rc=$?
if [ "$rc" -ne 7 ] || ! grep -q 'ERROR: workload scalar_loop failed on timed invocation 3 (exit 7)' "$SCRATCH/later.out"; then
    echo "SELFTEST FAILED: a failure on the third invocation was not named and rejected (exit $rc)"
    cat "$SCRATCH/later.out"
    exit 1
fi
if grep -q '^scalar_loop ' "$SCRATCH/later.out"; then
    echo "SELFTEST FAILED: the workload that failed on its third invocation received a result row"
    cat "$SCRATCH/later.out"
    exit 1
fi
echo "SELFTEST OK: clean control passed; a throwing workload and a failure on the third invocation were each named, rejected, and received no median"
