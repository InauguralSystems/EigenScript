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
# reproduces itself, it is a row. (2) Otherwise the arm is ledgered as unable
# to be adjudicated. Trace/replay opens the observer gate, so it cannot safely
# decide a divergence from any arm's ordinary gate configuration (#2122).
# Every arm receives the same process RNG seed, following V8's differential
# fuzzer --random-seed precedent (and Go's process-level randautoseed knob), so
# random output is comparable before trace/replay opens the observer gate.
# A timeout on one side is a divergence, not a pass.
# tests/jit_diff_expected.txt is the ledger. A '#' line or a blank line is a
# reason, not a row: both are stripped before the comparison and the count.
#   bash tools/jit_diff.sh            # compare against the ledger
#   bash tools/jit_diff.sh --record   # rewrite data rows; keep '#' lines
# Test only: JIT_DIFF_OBS_ONLY=<repo-relative file> runs just that OBS case,
# skipping the JIT and OSR arms and the normal OBS corpus.
set -u
# Phase 2 R1.3: every arm is headless, independent of the caller's display.
# A program requiring dummy drivers names them in the shared suite policy.
unset DISPLAY WAYLAND_DISPLAY XAUTHORITY
export SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy
if [ "${1:-}" = "--selftest" ] && [ "${JIT_DIFF_SELFTEST_SUITE:-0}" = "1" ]; then
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  cd "$ROOT" || exit 1
  # The timeout-both fixture outlives both 25 s OBS deadlines by design, so it
  # needs > 50 s; the row is keyed on the checker and fixtures (not on the
  # product test it replays), which keeps it off the 60 s product-row cap (#1352).
  timeout 90 env -u JIT_DIFF_SELFTEST_SUITE JIT_DIFF_OBS_ONLY=tests/fixtures/jit_diff_timeout_both.eigs bash tools/jit_diff.sh --selftest || exit 1
  timeout 30 env -u JIT_DIFF_SELFTEST_SUITE JIT_DIFF_SELFTEST_PLANT=deterministic JIT_DIFF_OBS_ONLY=tests/fixtures/jit_diff_taped_divergence.eigs bash tools/jit_diff.sh --selftest || exit 1
  timeout 30 env -u JIT_DIFF_SELFTEST_SUITE JIT_DIFF_SELFTEST_PLANT=gate_nondet JIT_DIFF_OBS_ONLY=tests/fixtures/jit_diff_gate_nondeterministic.eigs bash tools/jit_diff.sh --selftest || exit 1
  timeout 60 env -u JIT_DIFF_SELFTEST_SUITE JIT_DIFF_OBS_ONLY=tests/test_chunk_verify_stack.eigs bash tools/jit_diff.sh --selftest
  [ "$?" -eq 0 ] || exit 1
  selftest_ledger=$(mktemp); selftest_out=$(mktemp)
  trap 'rm -f "$selftest_ledger" "$selftest_out"' EXIT
  echo 'tests/fixtures/jit_diff_agreement.eigs OBS COULD_NOT_ADJUDICATE' > "$selftest_ledger"
  timeout 60 env -u JIT_DIFF_SELFTEST_SUITE JIT_DIFF_SELFTEST_COMPARE=1 JIT_DIFF_BASE="$selftest_ledger" JIT_DIFF_OBS_ONLY=tests/fixtures/jit_diff_agreement.eigs bash tools/jit_diff.sh --selftest > "$selftest_out" 2>&1 || {
    cat "$selftest_out"; echo "jit_diff: FAIL: absent ledgered COULD_NOT_ADJUDICATE row was rejected"; exit 1; }
  cat "$selftest_out"
  grep -Fq 'jit_diff: NOTE: ledgered COULD_NOT_ADJUDICATE row absent (pair agreed): tests/fixtures/jit_diff_agreement.eigs OBS COULD_NOT_ADJUDICATE' "$selftest_out" || {
    echo "jit_diff: FAIL: allowed absent row did not emit its NOTE"; exit 1; }
  echo 'tests/fixtures/jit_diff_agreement.eigs OBS' > "$selftest_ledger"
  if timeout 60 env -u JIT_DIFF_SELFTEST_SUITE JIT_DIFF_SELFTEST_COMPARE=1 JIT_DIFF_BASE="$selftest_ledger" JIT_DIFF_OBS_ONLY=tests/fixtures/jit_diff_agreement.eigs bash tools/jit_diff.sh --selftest > "$selftest_out" 2>&1; then
    cat "$selftest_out"; echo "jit_diff: FAIL: absent ordinary ledger row was accepted"; exit 1
  fi
  grep -Fq '< tests/fixtures/jit_diff_agreement.eigs OBS' "$selftest_out" || {
    cat "$selftest_out"; echo "jit_diff: FAIL: ordinary stale-row failure was not attributable"; exit 1; }
  echo 'jit_diff: PASS: absent ordinary ledger row remains stale'
  exit 0
fi
if [ "${1:-}" = "--selftest" ] && [ -z "${JIT_DIFF_OBS_ONLY:-}" ]; then
  echo "jit_diff: FAIL: --selftest requires JIT_DIFF_OBS_ONLY" >&2; exit 1
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT/src"
export EIGS_TEST_DIR="$ROOT/tests"
. "$ROOT/tests/suite_program_env.sh" || exit 1
EIG="${EIGS_BIN:-./eigenscript}"
BASE="${JIT_DIFF_BASE:-$ROOT/tests/jit_diff_expected.txt}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
got="$T/got"; : > "$got"; n=0; n_obs=0; n_deny=0; n_timeout=0; n_suite_env=0; adjudicated=0; could_not_adjudicate=0; run_seq=0
# Only address-shaped hex (8+ digits) is noise; a short 0x1 vs 0x0 is data.
norm() { sed -E 's/0x[0-9a-f]{8,}/0xADDR/g' "$1"; }
# Flags are on when non-empty and not "0". GNU env takes -u BEFORE assignments.
REF=(-u EIGS_JIT_OSR_THRESHOLD -u EIGS_OBS_FORCE -u EIGS_OBS_GATE_STATS EIGS_SEED_RANDOM=2120 EIGS_JIT_OFF=1)
JIT=(-u EIGS_JIT_OFF -u EIGS_JIT_OSR_THRESHOLD -u EIGS_OBS_FORCE -u EIGS_OBS_GATE_STATS EIGS_SEED_RANDOM=2120)
OSR=(-u EIGS_JIT_OFF -u EIGS_OBS_FORCE -u EIGS_OBS_GATE_STATS EIGS_SEED_RANDOM=2120 EIGS_JIT_OSR_THRESHOLD=1)
OBS=(-u EIGS_JIT_OSR_THRESHOLD -u EIGS_OBS_GATE_STATS EIGS_SEED_RANDOM=2120 EIGS_JIT_OFF=1 EIGS_OBS_FORCE=1)
if [ "${1:-}" = "--selftest" ] && { [ "${JIT_DIFF_SELFTEST_PLANT:-}" = "deterministic" ] || [ "${JIT_DIFF_SELFTEST_PLANT:-}" = "gate_nondet" ]; }; then
  OBS+=(EIGS_JIT_DIFF_SELFTEST_ARM=arm)
fi
run() { # $1 out-file, $2 seconds, rest = env args (options first)
  local out="$1" sec="$2" rc; shift 2
  local plant_seed=()
  run_seq=$((run_seq + 1))
  [ "${JIT_DIFF_SELFTEST_PLANT:-}" = "gate_nondet" ] && plant_seed=(EIGS_SEED_RANDOM=$((9000 + run_seq)))
  # Phase 2 owns run conditions in one checked loader, including the gfx Q7
  # dummy-driver policy. Keep main's seed and self-test plants on the same run.
  suite_program_check "$prog" > /dev/null || { echo "jit_diff: FAIL: suite environment lookup failed for $prog" >&2; exit 1; }
  ( if grep -Eq '(gfx|ui|audio)_[a-z_]+' "$prog"; then ulimit -v 1500000; fi
    suite_program_run "$prog" env "$@" "${plant_seed[@]}" timeout "$sec" "$EIG" "$prog"
  ) </dev/null > "$out" 2>&1
  rc=$?
  case " $* " in
    *' EIGS_JIT_DIFF_SELFTEST_ARM=arm '*)
      if [ "${JIT_DIFF_SELFTEST_PLANT:-}" = "gate_nondet" ]; then
        # Trace and replay force the observer gate open. Model a defect that
        # exists only on the ordinary, gate-closed path; the per-run plant seed supplies
        # real output variation and a tape stabilizes the random draw.
        case " $* " in *' EIGS_TRACE='*|*' EIGS_REPLAY='*) ;; *) echo "jit-diff gate-closed divergence plant" >> "$out" ;; esac
      else
        echo "jit-diff deterministic divergence plant" >> "$out"
      fi ;;
  esac
  echo "rc=$rc" >> "$out"
}
arm_env() { case "$1" in
  jit) AE=("${JIT[@]}") ;; osr) AE=("${OSR[@]}") ;; obs) AE=("${OBS[@]}") ;; esac; }
# Top-level tests/foo.eigs keeps the historical basename; anything deeper keeps
# its path (nested fixtures share basenames: peer.eigs, entry.eigs, ...).
row_of() { case "$1" in tests/*/*) printf '%s' "$1" ;; tests/*) basename "$1" ;; *) printf '%s' "$1" ;; esac; }
# #772 deliberately crosses the old 1e8-iteration truncation boundary. On the
# reference 2-core box REF finishes in 19.8s and forced OBS in 25.6s with the
# same result. Give this finite boundary test the existing JIT/OSR 180s bound
# in OBS too; keep every other OBS case at 25s and retain one-sided refusals.
obs_deadline() {
  case "$1" in tests/test_loop_cap_772.eigs) printf '180\n' ;; *) printf '25\n' ;; esac
}
# '#' lines and blank lines are reasons. Data rows are what the diff sees.
ledger_data() { awk 'NF && substr($0,1,1) != "#" { print }' "$1" | sort; }
ledger_count() { ledger_data "$1" | wc -l | tr -d ' '; }
b=jit_env_flags_float.eigs
selfcheck() { # $1 arm name, $2.. env args
  local arm="$1"; shift
  local st; st=$(env "$@" EIGS_JIT_STATS=1 timeout 60 "$EIG" "../tests/$b" 2>&1 >/dev/null | grep -o 'compiled=[0-9]*')
  [ -n "$st" ] || { echo "jit_diff: FAIL: the $arm arm did not run (no [jit] stats line)" >&2; exit 1; }
  echo "$st"
}
if [ -z "${JIT_DIFF_OBS_ONLY:-}" ]; then
  st=$(selfcheck REF "${REF[@]}") || exit 1; [ "$st" = compiled=0 ] || { echo "jit_diff: FAIL: the REF arm compiled ($st)"; exit 1; }
  st=$(selfcheck JIT "${JIT[@]}") || exit 1; [ "$st" != compiled=0 ] || { echo "jit_diff: FAIL: the JIT arm compiled nothing"; exit 1; }
  st=$(selfcheck OSR "${OSR[@]}") || exit 1; [ "$st" != compiled=0 ] || { echo "jit_diff: FAIL: the OSR arm compiled nothing"; exit 1; }
  st=$(selfcheck OBS "${OBS[@]}") || exit 1; [ "$st" = compiled=0 ] || { echo "jit_diff: FAIL: the OBS arm compiled ($st)"; exit 1; }
fi
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
  if [ "$rr" = "rc=124" ] && [ "$ar" = "rc=124" ]; then
    echo "jit_diff: $row $tag: timeout on both sides"
    return 2
  fi
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
  # A tape is not neutral here: recording/replay enables observer snapshots
  # and opens eigs_obs_gate_open(). It therefore cannot distinguish the OBS
  # arm, or a JIT/OSR defect confined to the gate-closed path. Fail closed and
  # put the category in the ledger rather than silently accepting the pair.
  could_not_adjudicate=$((could_not_adjudicate + 1))
  echo "$row $tag COULD_NOT_ADJUDICATE" >> "$got"
}
if [ -z "${JIT_DIFF_OBS_ONLY:-}" ]; then
for f in "$ROOT"/tests/test_*.eigs; do
  n=$((n + 1)); row=$(basename "$f"); prog="$f"
  run "$T/ref" 180 "${REF[@]}"
  suite_setting=$(suite_program_env "$prog") || { echo "jit_diff: FAIL: suite environment lookup failed for $prog"; exit 1; }
  if [ -n "$suite_setting" ]; then
    n_suite_env=$((n_suite_env + 1))
    [ "$(tail -n 1 "$T/ref")" = "rc=0" ] || {
      echo "jit_diff: FAIL: $row did not complete in REF under its suite environment"; tail -n 8 "$T/ref"; exit 1; }
  fi
  for arm in jit osr; do
    arm_env "$arm"
    run "$T/arm" 180 "${AE[@]}"
    if [ -n "$suite_setting" ] && [ "$(tail -n 1 "$T/arm")" != "rc=0" ]; then
      echo "jit_diff: FAIL: $row did not complete in $arm under its suite environment"; tail -n 8 "$T/arm"; exit 1
    fi
    consider "$arm" 180
  done
done
fi
# Denied up front: a source that uses gfx_open opens a window and cannot finish
# unattended in the headless gate; *seeded_race* and
# *userrace* (the deliberate #1489 positive-control race) are
# nondeterministic on purpose; *state_at*|*statedump* prints hash-order output.
# Phase 2's sole ownership declaration is checked on the broad population,
# before selecting a singleton self-test. Include owned untracked bank files
# in an unresolved merge, while main's OBS execution stays tracked-only.
if ! owned_tracked=$(git -c safe.directory="$ROOT" -C "$ROOT" ls-files '*.eigs' 2>/dev/null); then
  echo "jit_diff: FAIL: cannot enumerate the ownership corpus" >&2; exit 1
fi
printf '%s\n' "$owned_tracked" > "$T/owned-tracked"
(cd "$ROOT" && find tests -type f -name '*.eigs') > "$T/owned-tests"
LC_ALL=C sort -u "$T/owned-tracked" "$T/owned-tests" > "$T/ownership-corpus"
python3 "$ROOT/tools/phase2_corpus_exclude.py" "$ROOT" "$T/ownership-corpus" || exit 1
if [ -n "${JIT_DIFF_OBS_ONLY:-}" ]; then
  case "$JIT_DIFF_OBS_ONLY" in /*|../*|*/../*) echo "jit_diff: FAIL: JIT_DIFF_OBS_ONLY must be repository-relative" >&2; exit 1 ;; esac
  obs_files=$JIT_DIFF_OBS_ONLY
  git -c safe.directory="$ROOT" -C "$ROOT" ls-files --error-unmatch "$obs_files" >/dev/null 2>&1 || {
    echo "jit_diff: FAIL: JIT_DIFF_OBS_ONLY is not tracked: $obs_files" >&2; exit 1; }
elif ! obs_files=$(git -c safe.directory="$ROOT" -C "$ROOT" ls-files '*.eigs' \
    ':!tests/fixtures/jit_diff_timeout_both.eigs' 2>/dev/null); then
  echo "jit_diff: FAIL: cannot enumerate the tracked OBS corpus" >&2; exit 1
fi
[ -n "$obs_files" ] || { echo "jit_diff: FAIL: tracked OBS corpus is empty" >&2; exit 1; }
if [ -n "${JIT_DIFF_OBS_ONLY:-}" ] && ! grep -qxF -- "$obs_files" "$T/ownership-corpus"; then
  echo "jit_diff: FAIL: JIT_DIFF_OBS_ONLY is outside the unowned OBS corpus: $obs_files" >&2; exit 1
fi
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  grep -qxF -- "$rel" "$T/ownership-corpus" || continue
  [ -f "$ROOT/$rel" ] || { echo "jit_diff: FAIL: OBS corpus entry missing: $rel" >&2; exit 1; }
  if grep -q 'gfx_open[[:space:]]*of' "$ROOT/$rel"; then
    n_deny=$((n_deny + 1))
    echo "jit_diff: $rel OBS: excluded (uses gfx_open; cannot finish unattended headless)"
    continue
  fi
  case "$rel" in
    *paint*|*_game*) n_deny=$((n_deny + 1)); echo "jit_diff: $rel OBS: excluded (interactive example)"; continue ;;
    *seeded_race*) n_deny=$((n_deny + 1)); echo "jit_diff: $rel OBS: excluded (intentionally nondeterministic)"; continue ;;
    *userrace*) n_deny=$((n_deny + 1)); echo "jit_diff: $rel OBS: excluded (deliberate #1489 positive-control race)"; continue ;;
    *state_at*|*statedump*) n_deny=$((n_deny + 1)); echo "jit_diff: $rel OBS: excluded (hash-order output)"; continue ;;
  esac
  row=$(row_of "$rel"); prog="$ROOT/$rel"
  obs_seconds=$(obs_deadline "$rel")
  if [ "$obs_seconds" != 25 ]; then
    echo "jit_diff: $rel OBS: finite loop-boundary regression uses ${obs_seconds}s in both arms"
  fi
  run "$T/ref" "$obs_seconds" "${REF[@]}"
  arm_env obs
  run "$T/arm" "$obs_seconds" "${AE[@]}"
  consider obs "$obs_seconds"
  considered=$?
  if [ "$considered" -eq 2 ]; then
    n_timeout=$((n_timeout + 1))
  else
    n_obs=$((n_obs + 1))
  fi
done <<EOF
$obs_files
EOF
sort -o "$got" "$got"
if [ -z "${JIT_DIFF_OBS_ONLY:-}" ]; then
  [ "$n" -ge 100 ] || { echo "jit_diff: only $n JIT programs found -- the scan is vacuous"; exit 1; }
  [ "$n_suite_env" -eq 16 ] || { echo "jit_diff: FAIL: suite-environment programs completed=$n_suite_env, expected=16"; exit 1; }
  [ "$n_obs" -ge 500 ] || { echo "jit_diff: FAIL: OBS examined=$n_obs denied=$n_deny (floor 500)"; exit 1; }
fi
echo "jit_diff: OBS examined=$n_obs denied=$n_deny timeout-both=$n_timeout"
if [ -n "${JIT_DIFF_OBS_ONLY:-}" ] && [ -z "${JIT_DIFF_SELFTEST_COMPARE:-}" ]; then
  [ "${1:-}" = "--selftest" ] && cat "$got"
  exit 0
fi
if [ "${1:-}" = "--record" ]; then
  { awk '/^#/ { print }' "$BASE"; echo; cat "$got"; } > "$T/ledger"
  cp "$T/ledger" "$BASE"
  echo "jit_diff: baseline recorded ($(ledger_count "$BASE") rows, JIT $n, OBS examined=$n_obs denied=$n_deny, $adjudicated arms adjudicated, $could_not_adjudicate could not adjudicate)"
  exit 0
fi
[ -f "$BASE" ] || { echo "jit_diff: no baseline at $BASE (run with --record)"; cat "$got"; exit 1; }
nled=$(ledger_count "$BASE")
# COULD_NOT_ADJUDICATE records an unstable pair that may agree on a later run.
# Its absence is therefore informational. All present and ordinary rows remain
# an exact, bidirectional ledger comparison.
ledger_data "$BASE" | awk '$NF == "COULD_NOT_ADJUDICATE"' > "$T/optional"
comm -23 "$T/optional" "$got" > "$T/absent_optional"
ledger_data "$BASE" | awk '$NF != "COULD_NOT_ADJUDICATE"' > "$T/required"
comm -23 "$T/required" "$got" > "$T/absent_required"
comm -13 <(ledger_data "$BASE") "$got" > "$T/unexpected"
if [ ! -s "$T/absent_required" ] && [ ! -s "$T/unexpected" ]; then
  while IFS= read -r absent; do
    [ -n "$absent" ] && echo "jit_diff: NOTE: ledgered COULD_NOT_ADJUDICATE row absent (pair agreed): $absent"
  done < "$T/absent_optional"
  echo "jit_diff: OK ($n programs x {jit, osr} vs the interpreter; suite-env completed=$n_suite_env; OBS examined=$n_obs denied=$n_deny; $adjudicated arms adjudicated; $could_not_adjudicate could not adjudicate; $nled ledgered)"; exit 0
fi
diff <(ledger_data "$BASE") "$got" > "$T/d" || true
echo "jit_diff: LEDGER CHANGED (JIT $n, OBS examined=$n_obs denied=$n_deny)"
echo "  '<' = ledgered and now identical (improvement -- remove it)"
echo "  '>' = newly diverging from the interpreter (REGRESSION)"
cat "$T/d"; exit 1
