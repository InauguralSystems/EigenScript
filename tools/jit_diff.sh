#!/usr/bin/env bash
# jit_diff.sh -- the JIT's oracle is the INTERPRETER.
#
# Every tests/test_*.eigs runs three ways and stdout+stderr+rc are compared:
#   ref  EIGS_JIT_OFF=1                       -- the interpreter
#   jit  default JIT                          -- must equal ref
#   osr  EIGS_JIT_OSR_THRESHOLD=1             -- maximal native coverage; must equal ref
# A plain divergence is ADJUDICATED in two steps. (1) Determinism: both sides
# run once more; if each side reproduces itself, the divergence is the JIT's
# and it is a row. (2) Otherwise the program is nondeterministic (random,
# clock, fs probes): the interpreter records a tape (EIGS_TRACE) and the JIT
# arm replays it (EIGS_REPLAY), pinning the nondeterminism to the reference
# run; only a divergence that survives replay is a row. Why this order: on
# the first readings two `random`-seeded programs diverged under every tier
# run-to-run (replay made them identical); replay-everything produced 26
# phantom rows on thread/proc/file programs whose tape does not replay
# faithfully even with the JIT off on both sides (#1072); and replay-on-
# divergence alone LAUNDERED a deterministic divergence (#1071's line stamp
# happens to agree under replay), which step (1) now catches.
# tests/jit_diff_expected.txt is the ledger of KNOWN, FILED divergences -- a
# ledger to work down, never an amnesty.
#   bash tools/jit_diff.sh            # compare against the baseline
#   bash tools/jit_diff.sh --record   # rewrite the baseline from this run
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT/src"
EIG="${EIGS_BIN:-./eigenscript}"
BASE="$ROOT/tests/jit_diff_expected.txt"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
got="$T/got"; : > "$got"; n=0; adjudicated=0
norm() { sed -E 's/0x[0-9a-f]+/0xADDR/g' "$1"; }
# Arm environments. Since #1032 every boolean flag reads through
# eigs_env_flag (non-empty and not "0" = on), so `EIGS_JIT_OFF=` and
# `EIGS_JIT_OFF=0` both leave the JIT ON. The arms still UNSET it rather
# than rely on that: before #1032 jit.c tested getenv() for PRESENCE, the
# first version assigned it empty, and the "JIT" arm was the interpreter
# comparing itself to itself -- a clean ledger with a known deterministic
# divergence (#1071) missing from it. Section [99y] now pins the =0 form.
# GNU env takes its OPTIONS (-u NAME) only BEFORE the first assignment; an
# assignment-first list makes `-u` the command name, every run dies rc 127,
# and every arm "diverges" (442 rows on one reading). Options first, always.
REF=(-u EIGS_JIT_OSR_THRESHOLD EIGS_JIT_OFF=1)
JIT=(-u EIGS_JIT_OFF -u EIGS_JIT_OSR_THRESHOLD)
OSR=(-u EIGS_JIT_OFF EIGS_JIT_OSR_THRESHOLD=1)
run() { # $1 out-file, rest = env args (options first, then assignments)
  local out="$1"; shift
  env "$@" timeout 180 "$EIG" "../tests/$b" > "$out" 2>&1; echo "rc=$?" >> "$out"
}
# Self-check, before any comparison: every arm must RUN (a `[jit] scanned=`
# stats line proves the binary executed under that arm's environment), the
# JIT arms must COMPILE something, and the reference must compile NOTHING.
# Without this the oracle can compare the interpreter to itself (a clean
# ledger) or a dead arm to a live one (every row red) and look plausible.
b=bench_idxset.eigs
selfcheck() { # $1 arm name, $2.. env args
  local arm="$1"; shift
  local st; st=$(env "$@" EIGS_JIT_STATS=1 timeout 60 "$EIG" "../tests/$b" 2>&1 >/dev/null | grep -o 'compiled=[0-9]*')
  [ -n "$st" ] || { echo "jit_diff: FAIL: the $arm arm did not run (no [jit] stats line) -- check its environment" >&2; exit 1; }
  echo "$st"
}
st=$(selfcheck REF "${REF[@]}") || exit 1; [ "$st" = compiled=0 ] || { echo "jit_diff: FAIL: the REF arm compiled ($st) -- the reference must be the interpreter"; exit 1; }
st=$(selfcheck JIT "${JIT[@]}") || exit 1; [ "$st" != compiled=0 ] || { echo "jit_diff: FAIL: the JIT arm compiled nothing -- it would compare the interpreter to itself"; exit 1; }
st=$(selfcheck OSR "${OSR[@]}") || exit 1; [ "$st" != compiled=0 ] || { echo "jit_diff: FAIL: the OSR arm compiled nothing"; exit 1; }
for f in "$ROOT"/tests/test_*.eigs; do
  b=$(basename "$f"); n=$((n + 1))
  run "$T/ref" "${REF[@]}"
  run "$T/jit" "${JIT[@]}"
  run "$T/osr" "${OSR[@]}"
  for arm in jit osr; do
    diff -q <(norm "$T/ref") <(norm "$T/$arm") >/dev/null && continue
    # plain divergence, step 1: is it deterministic on both sides?
    adjudicated=$((adjudicated + 1))
    run "$T/ref2" "${REF[@]}"
    if [ "$arm" = jit ]; then run "$T/arm2" "${JIT[@]}"; else run "$T/arm2" "${OSR[@]}"; fi
    if diff -q <(norm "$T/ref") <(norm "$T/ref2") >/dev/null && diff -q <(norm "$T/$arm") <(norm "$T/arm2") >/dev/null; then
      echo "$b $(echo $arm | tr a-z A-Z)" >> "$got"; continue
    fi
    # step 2: nondeterministic program -- adjudicate under replay
    rm -f "$T/tape"
    run "$T/rref" "${REF[@]}" EIGS_TRACE="$T/tape"
    if [ "$arm" = jit ]; then run "$T/rarm" "${JIT[@]}" EIGS_REPLAY="$T/tape"
    else run "$T/rarm" "${OSR[@]}" EIGS_REPLAY="$T/tape"; fi
    diff -q <(norm "$T/rref") <(norm "$T/rarm") >/dev/null && continue
    echo "$b $(echo $arm | tr a-z A-Z)" >> "$got"
  done
done
sort -o "$got" "$got"
[ "$n" -ge 100 ] || { echo "jit_diff: only $n programs found -- the scan is vacuous"; exit 1; }
if [ "${1:-}" = "--record" ]; then cp "$got" "$BASE"; echo "jit_diff: baseline recorded ($(wc -l < "$BASE") rows, $n programs, $adjudicated arms adjudicated by replay)"; exit 0; fi
[ -f "$BASE" ] || { echo "jit_diff: no baseline at $BASE (run with --record)"; cat "$got"; exit 1; }
if diff <(sort "$BASE") "$got" > "$T/d"; then
  echo "jit_diff: OK ($n programs x {jit, osr} vs the interpreter; $adjudicated arms adjudicated by replay; $(wc -l < "$BASE") ledgered)"; exit 0
fi
echo "jit_diff: LEDGER CHANGED ($n programs examined)"
echo "  '<' = ledgered and now identical (improvement -- remove it)"
echo "  '>' = newly diverging from the interpreter (REGRESSION)"
cat "$T/d"; exit 1
