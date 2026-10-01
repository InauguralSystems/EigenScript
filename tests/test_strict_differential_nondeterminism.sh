#!/usr/bin/env bash
# Planted faults for #1399: distinguish an unstable strict run from a stable
# unset-vs-strict difference. The selftest uses the live classifier.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
out="$(bash "$ROOT/tools/strict_differential.sh" --selftest 2>&1)"
rc=$?

if [ "$rc" = 0 ] \
   && case "$out" in *"NONDETERMINISTIC (not a flag difference):"*) true ;; *) false ;; esac \
   && case "$out" in *"random-output probe (unset arm)"*) true ;; *) false ;; esac \
   && case "$out" in *"random="*"-first"*"random="*"-second"*) true ;; *) false ;; esac \
   && case "$out" in *"UNSET DIFFERS FROM EIGS_STRICT=1 (the default is not strict):"*) true ;; *) false ;; esac \
   && case "$out" in *"reverted-default probe"*"strict-tail"*) true ;; *) false ;; esac \
   && case "$out" in *"SELFTEST PASS: strict differential diagnoses both planted faults"*) true ;; *) false ;; esac; then
    echo "PASS: strict differential nondeterminism selftest"
    exit 0
fi

echo "FAIL: strict differential nondeterminism selftest (rc=$rc)"
printf '%s\n' "$out"
exit 1
