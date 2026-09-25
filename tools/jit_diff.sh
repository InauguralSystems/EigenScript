#!/usr/bin/env bash
# jit_diff.sh -- the JIT's oracle is the INTERPRETER.
#
# Every tests/test_*.eigs runs four ways; stdout+stderr+rc are compared to ref:
#   ref  EIGS_JIT_OFF=1                         interpreter, observer gate default
#   jit  default JIT                            must equal ref
#   osr  EIGS_JIT_OSR_THRESHOLD=1               maximal native coverage; must equal ref
#   obs  EIGS_JIT_OFF=1 EIGS_OBS_FORCE=1        interpreter, observer gate forced open
# A plain divergence is adjudicated. (1) Determinism: both sides run once more;
# if each reproduces itself, the divergence is a ledger row. (2) Otherwise the
# program is nondeterministic: ref records a tape (EIGS_TRACE) and the other
# arm replays it (EIGS_REPLAY); only a divergence that survives replay is a row.
# tests/jit_diff_expected.txt is the ledger of known divergences, not an amnesty.
#   bash tools/jit_diff.sh            # compare against the ledger
#   bash tools/jit_diff.sh --record   # rewrite the ledger from this run
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT/src"
EIG="${EIGS_BIN:-./eigenscript}"
BASE="$ROOT/tests/jit_diff_expected.txt"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
got="$T/got"; : > "$got"; n=0; adjudicated=0
norm() { sed -E 's/0x[0-9a-f]+/0xADDR/g' "$1"; }
# Flags are on when non-empty and not "0". GNU env takes -u BEFORE assignments.
REF=(-u EIGS_JIT_OSR_THRESHOLD -u EIGS_OBS_FORCE -u EIGS_OBS_GATE_STATS EIGS_JIT_OFF=1)
JIT=(-u EIGS_JIT_OFF -u EIGS_JIT_OSR_THRESHOLD -u EIGS_OBS_FORCE -u EIGS_OBS_GATE_STATS)
OSR=(-u EIGS_JIT_OFF -u EIGS_OBS_FORCE -u EIGS_OBS_GATE_STATS EIGS_JIT_OSR_THRESHOLD=1)
OBS=(-u EIGS_JIT_OSR_THRESHOLD -u EIGS_OBS_GATE_STATS EIGS_JIT_OFF=1 EIGS_OBS_FORCE=1)
run() { # $1 out-file, rest = env args (options first)
  local out="$1"; shift
  env "$@" timeout 180 "$EIG" "../tests/$b" > "$out" 2>&1; echo "rc=$?" >> "$out"
}
arm_env() { case "$1" in
  jit) AE=("${JIT[@]}") ;; osr) AE=("${OSR[@]}") ;; obs) AE=("${OBS[@]}") ;; esac; }
b=bench_idxset.eigs
selfcheck() { # $1 arm name, $2.. env args
  local arm="$1"; shift
  local st; st=$(env "$@" EIGS_JIT_STATS=1 timeout 60 "$EIG" "../tests/$b" 2>&1 >/dev/null | grep -o 'compiled=[0-9]*')
  [ -n "$st" ] || { echo "jit_diff: FAIL: the $arm arm did not run (no [jit] stats line)" >&2; exit 1; }
  echo "$st"
}
st=$(selfcheck REF "${REF[@]}") || exit 1; [ "$st" = compiled=0 ] || { echo "jit_diff: FAIL: the REF arm compiled ($st)"; exit 1; }
st=$(selfcheck JIT "${JIT[@]}") || exit 1; [ "$st" != compiled=0 ] || { echo "jit_diff: FAIL: the JIT arm compiled nothing"; exit 1; }
st=$(selfcheck OSR "${OSR[@]}") || exit 1; [ "$st" != compiled=0 ] || { echo "jit_diff: FAIL: the OSR arm compiled nothing"; exit 1; }
st=$(selfcheck OBS "${OBS[@]}") || exit 1; [ "$st" = compiled=0 ] || { echo "jit_diff: FAIL: the OBS arm compiled ($st)"; exit 1; }
# The arms must differ in mechanism, not only in name: a program the gate
# elides is unobserved on REF and observed when EIGS_OBS_FORCE is honoured.
printf 'print of 1\n' > "$T/elide.eigs"
gref=$(env "${REF[@]}" EIGS_OBS_GATE_STATS=1 timeout 30 "$EIG" "$T/elide.eigs" 2>&1 >/dev/null | grep -o 'obs-gate: [a-z]*' | head -1)
gobs=$(env "${OBS[@]}" EIGS_OBS_GATE_STATS=1 timeout 30 "$EIG" "$T/elide.eigs" 2>&1 >/dev/null | grep -o 'obs-gate: [a-z]*' | head -1)
[ "$gref" = "obs-gate: unobserved" ] && [ "$gobs" = "obs-gate: observed" ] || {
  echo "jit_diff: FAIL: OBS and REF do not differ in gate state ($gref vs $gobs)"; exit 1; }
for f in "$ROOT"/tests/test_*.eigs; do
  b=$(basename "$f"); n=$((n + 1))
  run "$T/ref" "${REF[@]}"
  for arm in jit osr obs; do
    arm_env "$arm"
    run "$T/$arm" "${AE[@]}"
    diff -q <(norm "$T/ref") <(norm "$T/$arm") >/dev/null && continue
    adjudicated=$((adjudicated + 1))
    run "$T/ref2" "${REF[@]}"
    run "$T/arm2" "${AE[@]}"
    if diff -q <(norm "$T/ref") <(norm "$T/ref2") >/dev/null && diff -q <(norm "$T/$arm") <(norm "$T/arm2") >/dev/null; then
      echo "$b $(echo "$arm" | tr a-z A-Z)" >> "$got"; continue
    fi
    rm -f "$T/tape"
    run "$T/rref" "${REF[@]}" EIGS_TRACE="$T/tape"
    run "$T/rarm" "${AE[@]}" EIGS_REPLAY="$T/tape"
    diff -q <(norm "$T/rref") <(norm "$T/rarm") >/dev/null && continue
    echo "$b $(echo "$arm" | tr a-z A-Z)" >> "$got"
  done
done
sort -o "$got" "$got"
[ "$n" -ge 100 ] || { echo "jit_diff: only $n programs found -- the scan is vacuous"; exit 1; }
if [ "${1:-}" = "--record" ]; then cp "$got" "$BASE"; echo "jit_diff: baseline recorded ($(wc -l < "$BASE") rows, $n programs, $adjudicated arms adjudicated)"; exit 0; fi
[ -f "$BASE" ] || { echo "jit_diff: no baseline at $BASE (run with --record)"; cat "$got"; exit 1; }
if diff <(sort "$BASE") "$got" > "$T/d"; then
  echo "jit_diff: OK ($n programs x {jit, osr, obs} vs the interpreter; $adjudicated arms adjudicated; $(wc -l < "$BASE") ledgered)"; exit 0
fi
echo "jit_diff: LEDGER CHANGED ($n programs examined)"
echo "  '<' = ledgered and now identical (improvement -- remove it)"
echo "  '>' = newly diverging from the interpreter (REGRESSION)"
cat "$T/d"; exit 1
