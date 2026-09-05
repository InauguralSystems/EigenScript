#!/usr/bin/env bash
# #1072: same-binary tape REPLAY fidelity, the tape's own contract (docs/TRACE.md:
# a tape recorded and replayed by the same binary reproduces stdout+stderr+rc).
# jit_diff.sh leans on this contract to adjudicate nondeterministic programs, so
# every hole in it is a hole in that oracle too.
#
# For every corpus program (JIT off on both sides so the JIT is not the
# variable): record a tape, replay it, normalize, diff. A divergence is one of:
#   BOUNDARY  the replay stderr names the documented subprocess/concurrency
#             boundary ("not replayable under EIGS_REPLAY") -- by design (#148),
#             counted, never a row;
#   ROW       anything else -- a fidelity hole, ledgered in
#             tests/replay_diff_expected.txt (a ledger to work down, never an
#             amnesty; the count only goes down).
# Self-check before comparing: the record arm must WRITE a tape (a run that
# never traced would replay itself trivially green), and the replay arm must
# READ it (EIGS_REPLAY of a missing tape is refused by name).
#
# Usage: bash tools/replay_diff.sh [--record]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT/src" || exit 1
EIG=./eigenscript; BASE="$ROOT/tests/replay_diff_expected.txt"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
got="$T/got"; : > "$got"; n=0; boundary=0; nondet=0
norm() { sed -E 's/0x[0-9a-f]+/0xADDR/g' "$1"; }
# stdin is pinned to /dev/null: test_terminal's raw_key reads it, and with the
# harness's inherited stdin the record arm hung (rc 124) while the replay arm
# exited 3 -- a phantom row from the environment, not the tape.
run() { local out="$1"; shift; env -u EIGS_JIT_OSR_THRESHOLD EIGS_JIT_OFF=1 "$@" timeout 180 "$EIG" "../tests/$b" > "$out" 2>&1 </dev/null; echo "rc=$?" >> "$out"; }
# self-check on a known-deterministic program
b=test_math_underflow.eigs
[ -f "../tests/$b" ] || b=$(ls ../tests/test_*.eigs | head -1 | xargs basename)
rm -f "$T/tape0"; run "$T/r0" EIGS_TRACE="$T/tape0"
[ -s "$T/tape0" ] || { echo "replay_diff: FAIL: the record arm wrote no tape for $b -- check EIGS_TRACE"; exit 1; }
run "$T/p0" EIGS_REPLAY="$T/tape0"
diff -q <(norm "$T/r0") <(norm "$T/p0") >/dev/null || { echo "replay_diff: FAIL: the self-check program $b does not replay its own tape"; diff <(norm "$T/r0") <(norm "$T/p0") | head -5; exit 1; }
for f in "$ROOT"/tests/test_*.eigs; do
  b=$(basename "$f"); n=$((n + 1))
  rm -f "$T/tape"
  run "$T/rec" EIGS_TRACE="$T/tape"
  run "$T/rep" EIGS_REPLAY="$T/tape"
  # A crash that the two arms AGREE on is invisible to the diff; name it so a
  # crashing corpus program is never silently "identical" (one run of this
  # tool printed a bash "Segmentation fault" line that no row explained).
  for arm in rec rep; do r=$(tail -1 "$T/$arm" | sed 's/rc=//'); [ "$r" -ge 128 ] 2>/dev/null && echo "  CRASH $b $arm arm rc=$r"; done
  diff -q <(norm "$T/rec") <(norm "$T/rep") >/dev/null && continue
  if grep -q "not replayable under EIGS_REPLAY" "$T/rep"; then boundary=$((boundary + 1)); continue; fi
  # Adjudicate (jit_diff's step 1): a program whose record arm is not even
  # deterministic against itself is NONDET -- counted, reported, not a row.
  rm -f "$T/tape2"; run "$T/rec2" EIGS_TRACE="$T/tape2"; run "$T/rep2" EIGS_REPLAY="$T/tape2"
  if ! diff -q <(norm "$T/rec") <(norm "$T/rec2") >/dev/null; then nondet=$((nondet + 1)); echo "  NONDET $b (record arm differs from itself)"; continue; fi
  if diff -q <(norm "$T/rec2") <(norm "$T/rep2") >/dev/null; then nondet=$((nondet + 1)); echo "  NONDET $b (replay diverged once, then matched)"; continue; fi
  for arm in rec rep; do r=$(tail -1 "$T/$arm" | sed 's/rc=//'); [ "$r" -ge 128 ] 2>/dev/null && echo "  CRASH $b $arm arm rc=$r"; done
  echo "$b" >> "$got"
done
sort -o "$got" "$got"
[ "$n" -ge 100 ] || { echo "replay_diff: only $n programs found -- the scan is vacuous"; exit 1; }
if [ "${1:-}" = "--record" ]; then cp "$got" "$BASE"; echo "replay_diff: baseline recorded ($(wc -l < "$BASE") rows, $n programs, $boundary at the documented boundary, $nondet nondeterministic)"; exit 0; fi
[ -f "$BASE" ] || { echo "replay_diff: no baseline at $BASE (run with --record)"; cat "$got"; exit 1; }
if diff <(sort "$BASE") "$got" > "$T/d"; then
  echo "replay_diff: OK ($n programs record+replay; $boundary at the documented boundary; $nondet nondeterministic; $(wc -l < "$BASE") ledgered)"; exit 0
fi
echo "replay_diff: LEDGER CHANGED ($n programs examined)"
echo "  '<' = ledgered and now identical (improvement -- remove it)"
echo "  '>' = newly diverging on replay (REGRESSION)"
cat "$T/d"; exit 1
