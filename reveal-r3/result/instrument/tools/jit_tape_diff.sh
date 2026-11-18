#!/usr/bin/env bash
# Exact trace-tape differential: the interpreter is the JIT/OSR oracle.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EIG="${EIGS_BIN:-$ROOT/src/eigenscript}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
n=0

for prog in "$ROOT"/tests/jit_tape/*.eigs; do
    [ -f "$prog" ] || { echo "jit_tape_diff: FAIL: empty corpus"; exit 1; }
    n=$((n + 1))
    base=$(basename "$prog" .eigs)
    env -u EIGS_JIT_OSR_THRESHOLD EIGS_JIT_OFF=1 EIGS_TRACE="$T/ref.tape" \
        "$EIG" "$prog" </dev/null >"$T/ref.out" 2>"$T/ref.err" || {
        echo "jit_tape_diff: FAIL: $base interpreter run"; cat "$T/ref.err"; exit 1; }
    for arm in jit osr; do
        if [ "$arm" = jit ]; then
            env -u EIGS_JIT_OFF -u EIGS_JIT_OSR_THRESHOLD EIGS_TRACE="$T/$arm.tape" \
                "$EIG" "$prog" </dev/null >"$T/$arm.out" 2>"$T/$arm.err"
        else
            env -u EIGS_JIT_OFF EIGS_JIT_OSR_THRESHOLD=1 EIGS_TRACE="$T/$arm.tape" \
                "$EIG" "$prog" </dev/null >"$T/$arm.out" 2>"$T/$arm.err"
        fi
        rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "jit_tape_diff: FAIL: $base $arm run (rc=$rc)"; cat "$T/$arm.err"; exit 1
        fi
        if ! cmp -s "$T/ref.out" "$T/$arm.out" || ! cmp -s "$T/ref.err" "$T/$arm.err"; then
            echo "jit_tape_diff: FAIL: $base $arm output differs from interpreter"; exit 1
        fi
        if ! cmp -s "$T/ref.tape" "$T/$arm.tape"; then
            echo "jit_tape_diff: FAIL: $base $arm tape differs from interpreter"
            diff -u "$T/ref.tape" "$T/$arm.tape" >"$T/tape.diff" || true
            sed -n '1,40p' "$T/tape.diff"
            exit 1
        fi
    done
done

[ "$n" -gt 0 ] || { echo "jit_tape_diff: FAIL: empty corpus"; exit 1; }
echo "jit_tape_diff: OK ($n programs x {jit, osr} tapes vs the interpreter)"
