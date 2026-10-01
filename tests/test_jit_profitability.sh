#!/usr/bin/env bash
set -u
EIGS="${EIGS:-$(cd "$(dirname "$0")/../src" && pwd)/eigenscript}"
PROG="$(cd "$(dirname "$0")" && pwd)/test_jit_profitability.eigs"

run() { env "$@" "$EIGS" "$PROG" 2>&1; }
base=$(run EIGS_JIT_DUMP_SELECTION=1 EIGS_JIT_ENTRY_THRESHOLD=2 EIGS_JIT_OSR_THRESHOLD=100)
off=$(run EIGS_JIT_DUMP_SELECTION=1 EIGS_JIT_ENTRY_THRESHOLD=2 EIGS_JIT_OSR_THRESHOLD=100 EIGS_JIT_OFF=1)

printf '%s\n' "$base" | grep -q "chunk='tiny_entry'.*scope=entry.*decision=reject" || { echo "FAIL: tiny entry was not rejected"; exit 1; }
printf '%s\n' "$base" | grep -q "chunk='large_entry'.*scope=entry.*decision=accept" || { echo "FAIL: large entry was not accepted"; exit 1; }
printf '%s\n' "$base" | grep -q "chunk='osr_entry'.*scope=osr.*decision=accept" || { echo "FAIL: OSR was not independently accepted"; exit 1; }
printf '%s\n' "$base" | grep -q "All tests passed" || { echo "FAIL: selected-tier output changed"; exit 1; }
printf '%s\n' "$off" | grep -q "All tests passed" || { echo "FAIL: EIGS_JIT_OFF output changed"; exit 1; }
if printf '%s\n' "$off" | grep -q '^JIT selection:'; then echo "FAIL: EIGS_JIT_OFF selected a tier"; exit 1; fi
echo "jit_profitability: OK"
