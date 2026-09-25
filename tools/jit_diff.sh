#!/usr/bin/env bash
# jit_diff.sh -- the JIT's oracle is the INTERPRETER.
#
# tests/test_*.eigs runs three ways; stdout+stderr+rc are compared to ref:
#   ref  EIGS_JIT_OFF=1                         interpreter, gate as default
#   jit  default JIT                            must equal ref
#   osr  EIGS_JIT_OSR_THRESHOLD=1               maximal native coverage; must equal ref
# JIT and OSR stay on tests/test_*.eigs. They are not widened in this change.
# The OBS arm is the old observer corpus: every tracked .eigs file, with the
# gate forced open (EIGS_JIT_OFF=1 EIGS_OBS_FORCE=1), compared to ref.
# A plain divergence is adjudicated. (1) Both sides run once more; if each
# reproduces itself, it is a row. (2) Otherwise ref records a tape and the
# other arm replays it; only a divergence that survives replay is a row.
# A timeout on one side is a divergence, not a pass.
# tests/jit_diff_expected.txt is the ledger. A '#' line or a blank line is a
# reason, not a row: both are stripped before the comparison and the count.
#   bash tools/jit_diff.sh            # compare against the ledger
#   bash tools/jit_diff.sh --record   # rewrite data rows; keep '#' lines
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT/src"
EIG="${EIGS_BIN:-./eigenscript}"
BASE="$ROOT/tests/jit_diff_expected.txt"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
got="$T/got"; : > "$got"; n=0; n_obs=0; n_deny=0; adjudicated=0
# Only address-shaped hex (8+ digits) is noise; a short 0x1 vs 0x0 is data.
norm() { sed -E 's/0x[0-9a-f]{8,}/0xADDR/g' "$1"; }
# Flags are on when non-empty and not "0". GNU env takes -u BEFORE assignments.
REF=(-u EIGS_JIT_OSR_THRESHOLD -u EIGS_OBS_FORCE -u EIGS_OBS_GATE_STATS EIGS_JIT_OFF=1)
JIT=(-u EIGS_JIT_OFF -u EIGS_JIT_OSR_THRESHOLD -u EIGS_OBS_FORCE -u EIGS_OBS_GATE_STATS)
OSR=(-u EIGS_JIT_OFF -u EIGS_OBS_FORCE -u EIGS_OBS_GATE_STATS EIGS_JIT_OSR_THRESHOLD=1)
OBS=(-u EIGS_JIT_OSR_THRESHOLD -u EIGS_OBS_GATE_STATS EIGS_JIT_OFF=1 EIGS_OBS_FORCE=1)
run() { # $1 out-file, $2 seconds, rest = env args (options first)
  local out="$1" sec="$2"; shift 2
  env "$@" timeout "$sec" "$EIG" "$prog" </dev/null > "$out" 2>&1; echo "rc=$?" >> "$out"
}
arm_env() { case "$1" in
  jit) AE=("${JIT[@]}") ;; osr) AE=("${OSR[@]}") ;; obs) AE=("${OBS[@]}") ;; esac; }
# Top-level tests/foo.eigs keeps the historical basename; anything deeper keeps
# its path (nested fixtures share basenames: peer.eigs, entry.eigs, ...).
row_of() { case "$1" in tests/*/*) printf '%s' "$1" ;; tests/*) basename "$1" ;; *) printf '%s' "$1" ;; esac; }
# '#' lines and blank lines are reasons. Data rows are what the diff sees.
ledger_data() { awk 'NF && substr($0,1,1) != "#" { print }' "$1" | sort; }
ledger_count() { ledger_data "$1" | wc -l | tr -d ' '; }
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
# The arms must differ in mechanism: a program the gate elides is unobserved
# on REF and observed when EIGS_OBS_FORCE is honoured.
printf 'print of 1\n' > "$T/elide.eigs"
gref=$(env "${REF[@]}" EIGS_OBS_GATE_STATS=1 timeout 30 "$EIG" "$T/elide.eigs" 2>&1 >/dev/null | grep -o 'obs-gate: [a-z]*' | head -1)
gobs=$(env "${OBS[@]}" EIGS_OBS_GATE_STATS=1 timeout 30 "$EIG" "$T/elide.eigs" 2>&1 >/dev/null | grep -o 'obs-gate: [a-z]*' | head -1)
[ "$gref" = "obs-gate: unobserved" ] && [ "$gobs" = "obs-gate: observed" ] || {
  echo "jit_diff: FAIL: OBS and REF do not differ in gate state ($gref vs $gobs)"; exit 1; }
# $1 arm, $2 timeout. $T/ref and $T/arm are already filled. $row is the ledger name.
consider() {
  local arm="$1" sec="$2" tag rr ar
  tag=$(printf '%s' "$arm" | tr a-z A-Z)
  rr=$(tail -n 1 "$T/ref"); ar=$(tail -n 1 "$T/arm")
  if { [ "$rr" = "rc=124" ] && [ "$ar" != "rc=124" ]; } || { [ "$ar" = "rc=124" ] && [ "$rr" != "rc=124" ]; }; then
    echo "$row $tag" >> "$got"; return
  fi
  diff -q <(norm "$T/ref") <(norm "$T/arm") >/dev/null && return
  adjudicated=$((adjudicated + 1))
  run "$T/ref2" "$sec" "${REF[@]}"
  run "$T/arm2" "$sec" "${AE[@]}"
  if diff -q <(norm "$T/ref") <(norm "$T/ref2") >/dev/null && diff -q <(norm "$T/arm") <(norm "$T/arm2") >/dev/null; then
    echo "$row $tag" >> "$got"; return
  fi
  rm -f "$T/tape"
  run "$T/rref" "$sec" "${REF[@]}" EIGS_TRACE="$T/tape"
  run "$T/rarm" "$sec" "${AE[@]}" EIGS_REPLAY="$T/tape"
  diff -q <(norm "$T/rref") <(norm "$T/rarm") >/dev/null && return
  echo "$row $tag" >> "$got"
}
for f in "$ROOT"/tests/test_*.eigs; do
  n=$((n + 1)); row=$(basename "$f"); prog="$f"
  run "$T/ref" 180 "${REF[@]}"
  for arm in jit osr; do
    arm_env "$arm"
    run "$T/arm" 180 "${AE[@]}"
    consider "$arm" 180
  done
done
# Denied up front: *gfx*|*paint*|*_game* opens a window; *seeded_race* is
# nondeterministic on purpose; *state_at*|*statedump* prints hash-order output.
obs_files=$(git -C "$ROOT" ls-files '*.eigs' 2>/dev/null || true)
if [ -z "$obs_files" ]; then
  obs_files=$(cd "$ROOT" && find . -name '*.eigs' -type f \
    -not -path './.git/*' -not -path './build/*' -not -path '*/eigs_modules/*' \
    | sed 's|^\./||')
fi
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case "$rel" in
    *gfx*|*paint*|*_game*|*seeded_race*|*state_at*|*statedump*) n_deny=$((n_deny + 1)); continue ;;
  esac
  [ -f "$ROOT/$rel" ] || { echo "jit_diff: FAIL: OBS corpus entry missing: $rel" >&2; exit 1; }
  n_obs=$((n_obs + 1)); row=$(row_of "$rel"); prog="$ROOT/$rel"
  run "$T/ref" 25 "${REF[@]}"
  arm_env obs
  run "$T/arm" 25 "${AE[@]}"
  consider obs 25
done <<EOF
$obs_files
EOF
sort -o "$got" "$got"
[ "$n" -ge 100 ] || { echo "jit_diff: only $n JIT programs found -- the scan is vacuous"; exit 1; }
[ "$n_obs" -ge 500 ] || { echo "jit_diff: FAIL: OBS examined=$n_obs denied=$n_deny (floor 500)"; exit 1; }
echo "jit_diff: OBS examined=$n_obs denied=$n_deny"
if [ "${1:-}" = "--record" ]; then
  { awk '/^#/ { print }' "$BASE"; echo; cat "$got"; } > "$T/ledger"
  cp "$T/ledger" "$BASE"
  echo "jit_diff: baseline recorded ($(ledger_count "$BASE") rows, JIT $n, OBS examined=$n_obs denied=$n_deny, $adjudicated arms adjudicated)"
  exit 0
fi
[ -f "$BASE" ] || { echo "jit_diff: no baseline at $BASE (run with --record)"; cat "$got"; exit 1; }
nled=$(ledger_count "$BASE")
if diff <(ledger_data "$BASE") "$got" > "$T/d"; then
  echo "jit_diff: OK ($n programs x {jit, osr} vs the interpreter; OBS examined=$n_obs denied=$n_deny; $adjudicated arms adjudicated; $nled ledgered)"; exit 0
fi
echo "jit_diff: LEDGER CHANGED (JIT $n, OBS examined=$n_obs denied=$n_deny)"
echo "  '<' = ledgered and now identical (improvement -- remove it)"
echo "  '>' = newly diverging from the interpreter (REGRESSION)"
cat "$T/d"; exit 1
