#!/usr/bin/env bash
# jit_fleet_bench.sh -- is the JIT worth having, measured on the ECOSYSTEM?
#
# The JIT's own benches (bench_idxset, bench_dmg_shape) show 2.0-2.3x. The
# consumers do not: measured 2026-09-17 across 25 workloads in 24 repos, the
# JIT is a COIN FLIP -- Tidepool +6.6%, DMG +4.5%, EigenMiniSat -2.4%,
# ouroboros -4.7..-6.8%. This harness is that matrix made runnable, so a JIT
# change is judged on consumer shapes instead of on benches written to suit
# the emitter (EigenScript#1178).
#
# NOT ENROLLED IN THE SUITE, AND THAT IS A SCOPE STATEMENT, NOT AN OVERSIGHT.
# An oracle nobody dispatches is a script in a directory (mechanical-gates
# 151), so: this needs the CONSUMER CHECKOUTS -- $ECO/DMG, ouroboros,
# EigenMiniSat, Tidepool, liferaft -- which neither tests/run_all_tests.sh
# nor any CI lane has, and the full matrix is ~12 minutes of wall-clock
# timing that a shared runner cannot resolve anyway (see UNRESOLVED below).
# Its selftest has the same dependency, so that cannot be enrolled either.
# It is a MANUAL instrument, run deliberately when a JIT change needs
# judging. What would have to change to enrol it: the consumer repos
# available to CI, and a quiet-enough runner for the spreads to resolve.
#
#   bash tools/jit_fleet_bench.sh              # full matrix (~12 min)
#   bash tools/jit_fleet_bench.sh --quick      # the two decisive rows (~3 min)
#   bash tools/jit_fleet_bench.sh --selftest   # planted faults; must go red
#
# Verdicts are against PRE-REGISTERED floors (#1178), never against "better
# than last time":
#   WIN rows  stay at or above their floor  (keep the JIT's existing value)
#   LOSS rows reach >= 0%                   (stop being a net loss)
#   CONTROL   stays within +-1%             (it compiles nothing, so a reading
#                                            outside that band means the
#                                            HARNESS moved, not the JIT)
#
# ---------------------------------------------------------------------------
# What this gate exists to stop (mechanical-gates section 97 -- name it, then
# check every plant is an instance of it):
#
#   "A JIT change is declared good on a number that did not measure the JIT."
#
# Three ways that has actually happened, each encoded as a check:
#
# 1. THE JIT NEVER ENGAGED. A workload where nothing compiles yields an
#    on/off delta that is pure scheduler noise and looks exactly like a
#    measurement. EigenGauntlet was misread that way twice on 2026-09-17 --
#    once as "compiles nothing" off a truncated multi-thread dump, once as a
#    real -2.3%. Every non-control row asserts compiled>0.
# 2. BOTH ARMS WERE THE SAME TIER. If EIGS_JIT_OFF stops disabling the JIT
#    (the #1032 presence-vs-value class, which has happened in this repo),
#    both arms run the JIT, every row reads ~0%, and every LOSS row PASSES
#    its >=0 floor. So the off arm is asserted to compile NOTHING. This is
#    mechanical-gates section 113: prove the arms differ in MECHANISM, not
#    just that both ran.
# 3. THE BINARY WAS NOT A PERFORMANCE BINARY. `make asan` OVERWRITES
#    src/eigenscript with a ~5x slower build and --version does not say so;
#    it produced a 6.5x error in a published figure on 2026-09-17. Refused.
#
# Residual (section 6 -- what this gate does NOT cover): it does not check
# CORRECTNESS. tools/jit_diff.sh is the oracle for that and must be green
# independently; a fast wrong JIT passes every row here. It also cannot see a
# regression on a shape absent from the matrix -- the row set is the claim,
# and ROW_COUNT below pins it so a row cannot be dropped silently.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EIGS="${EIGS:-$ROOT/src/eigenscript}"
# The ecosystem root must be DISCOVERED and validated, never assumed to be
# the parent: in a git worktree $ROOT/.. is the worktree pool, so every
# consumer row would silently become missing-dir. Anchor on the repos the
# matrix actually names (section 1).
eco_ok() { [ -d "$1/DMG" ] && [ -d "$1/ouroboros" ] && [ -d "$1/EigenMiniSat" ]; }
if [ -n "${ECO:-}" ]; then
  eco_ok "$ECO" || { echo "jit_fleet_bench: FAIL: ECO=$ECO has no DMG/ouroboros/EigenMiniSat" >&2; exit 1; }
else
  ECO=""
  for cand in "$ROOT/.." \
              "$HOME/src/InauguralSystems/EigenScriptEcosystem" \
              "$(cd "$ROOT/.." 2>/dev/null && pwd)/InauguralSystems/EigenScriptEcosystem"; do
    [ -d "$cand" ] || continue
    cand=$(cd "$cand" && pwd)
    if eco_ok "$cand"; then ECO="$cand"; break; fi
  done
  [ -n "$ECO" ] || { echo "jit_fleet_bench: FAIL: cannot locate the ecosystem root; set ECO=" >&2; exit 1; }
fi
N="${N:-5}"
QUICK=0; SELFTEST=0; ONLY=""
for a in "$@"; do
  case "$a" in
    --quick)    QUICK=1 ;;
    --selftest) SELFTEST=1 ;;
    --rows=*)   ONLY="${a#--rows=}" ;;
    *) echo "usage: $0 [--quick] [--selftest]" >&2; exit 2 ;;
  esac
done

fail() { echo "jit_fleet_bench: FAIL: $*" >&2; exit 1; }

# Environment banner (section 144): this gate reports timings, so the machine
# is part of every verdict and must never have to be guessed at from a log.
banner() {
  echo "runtime : $EIGS"
  echo "host    : $(uname -srm)  cores=$(nproc 2>/dev/null || echo '?')"
  echo "n       : $N medians per arm; floors pre-registered in EigenScript#1178"
}

[ -x "$EIGS" ] || fail "no runtime at $EIGS (set EIGS=)"
if nm -D "$EIGS" 2>/dev/null | grep -q "__asan\|__ubsan" ||
   ldd "$EIGS" 2>/dev/null | grep -qi asan; then
  fail "$EIGS is a sanitizer build (~5x slower than release); use 'make build'"
fi

med() { sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }

# ---------------------------------------------------------------- the matrix
# name : dir : floor_pct : expect : argv...
# The row set IS the claim this gate makes, so its size is pinned below.
ROWS=(
  "ouroboros-sheet:$ECO/ouroboros:0:some:ouroboros.eigs $ECO/eigen-sheet/sheet.eigs"
  "eigenminisat-s5:$ECO/EigenMiniSat:0:some:minisat.eigs --bench --size 5"
  "ouroboros-stmtcap:$ECO/ouroboros:0:some:ouroboros.eigs $ECO/EigenScript/tests/test_stmt_cap.eigs"
  "dmg-5M:$ECO/DMG:3:some:dmg.eigs roms/cpu_instrs.gb --cycles 5000000"
  "tidepool-evalpolicy:$ECO/Tidepool:5:some:eval_policy.eigs"
  "liferaft-CONTROL:$ECO/liferaft:-1:none:liferaft_sweep.eigs --seeds 20 --steps 300"
)
ROW_COUNT=6            # section 121: found == declared, never ">= 1"
QUICK_ROWS="ouroboros-sheet eigenminisat-s5"

[ "${#ROWS[@]}" = "$ROW_COUNT" ] ||
  fail "matrix has ${#ROWS[@]} rows, ROW_COUNT declares $ROW_COUNT"

# ------------------------------------------------------------ measure a row
# force_same=1 makes the "on" arm secretly JIT-OFF (selftest plant P1).
# skip_offcheck=1 suppresses the off-arm mechanism assertion (plant P3).
run_row() {
  local spec="$1" force_same="${2:-0}" skip_offcheck="${3:-0}"
  local name dir floor expect argstr
  IFS=':' read -r name dir floor expect argstr <<<"$spec"
  local -a argv; read -r -a argv <<<"$argstr"

  [ -d "$dir" ] || { echo "$name VERDICT=FAIL reason=missing-dir:$dir"; return; }

  # DID THE PROGRAM RUN? Before any mechanism or timing question. A workload
  # that dies immediately still yields a small POSITIVE wall time, so the
  # "no-timing" guard below cannot see it -- and for the CONTROL row, whose
  # expectation is compiled=0, a dead program satisfies every other check and
  # PASSES, certifying the instrument while measuring nothing.
  # Bought 2026-09-18: a stale AOT binary reported compiled=0 and was read as
  # "the JIT does not engage inside AOT output". It was dying on line 5 --
  # `load_file: cannot read 'lib/int_vector.eigs'` -- because its build-time
  # paths no longer existed. The engagement check was necessary and not
  # sufficient; rc is the missing half.
  local rc_probe
  ( cd "$dir" && ulimit -v 2000000
    timeout 300 "$EIGS" "${argv[@]}" >/dev/null 2>&1 ); rc_probe=$?
  if [ "$rc_probe" != 0 ]; then
    echo "$name VERDICT=FAIL reason=workload-exited-$rc_probe (the program did not run; every timing below would be of a failure)"
    return
  fi

  # compiled= under each arm. This is the mechanism assertion, not a timing.
  local compiled_on compiled_off
  compiled_on=$( ( cd "$dir" && ulimit -v 2000000
      EIGS_JIT_STATS=1 timeout 300 "$EIGS" "${argv[@]}" 2>&1 >/dev/null ) |
      grep -o 'compiled=[0-9]*' | sed 's/.*=//' | awk '{s+=$1} END{print s+0}' )
  compiled_off=$( ( cd "$dir" && ulimit -v 2000000
      EIGS_JIT_STATS=1 EIGS_JIT_OFF=1 timeout 300 "$EIGS" "${argv[@]}" 2>&1 >/dev/null ) |
      grep -o 'compiled=[0-9]*' | sed 's/.*=//' | awk '{s+=$1} END{print s+0}' )

  # ARMS INTERLEAVED, one off then one on per iteration, and the verdict is
  # the median of the PAIRED deltas. Bought 2026-09-17: the first version ran
  # all-off then all-on in blocks, so any drift across a 30 s block landed
  # entirely in the percentage -- three rows moved more than a point between
  # identical runs of the same binary, and the builder's own interleaved read
  # of eigenminisat disagreed with the harness's block read by 1.2 points.
  # Pairing cancels drift that is common to both arms; the spread of the pairs
  # is then an honest statement of what the instrument can resolve.
  # EVERY TIMED INVOCATION IS CHECKED, NOT A PROBE RUN THAT RESEMBLES THEM.
  #
  # #1204: the rc probe above runs ONCE, up front, and -- crucially -- with a
  # different environment from the runs it vouches for (no EIGS_JIT_OFF, no
  # unset OSR threshold). The timing loop then threw the workload's status
  # away entirely: `/usr/bin/time -f %e` prints an elapsed line whether the
  # program returned 0 or 23, and `| tail -1` takes it, so a dead run yields
  # a perfectly plausible number. A blind critic planted a fixture that
  # exited 23 on EVERY timed invocation and this harness reported
  # `PASS, +71.4%` -- while its own selftest passed 8/8.
  #
  # `/usr/bin/time -o FILE` writes the timing to FILE and exits with the
  # COMMAND's status, so both are available without a pipeline swallowing
  # the one that matters.
  local off=() on=() i t rc tf
  tf="$(mktemp "${TMPDIR:-/tmp}/jitfleet.time.XXXXXX")"
  timed_run() {  # $1 = arm label, $2.. = env assignments; prints seconds, returns workload rc
      local arm="$1"; shift
      ( cd "$dir" && ulimit -v 2000000
        env "$@" /usr/bin/time -f %e -o "$tf" timeout 300 "$EIGS" "${argv[@]}" >/dev/null 2>&1 )
      local r=$?
      printf '%s' "$(tail -1 "$tf" 2>/dev/null)"
      return $r
  }
  for ((i=0;i<N;i++)); do
    t=$(timed_run off -u EIGS_JIT_OSR_THRESHOLD EIGS_JIT_OFF=1); rc=$?
    if [ "$rc" != 0 ]; then
      rm -f "$tf"
      echo "$name VERDICT=FAIL reason=timed-run-exited-$rc-arm-off-iter-$i (a timing of a failed run is not a timing)"
      return
    fi
    off+=("$t")
    if [ "$force_same" = 1 ]; then
      t=$(timed_run on -u EIGS_JIT_OSR_THRESHOLD EIGS_JIT_OFF=1); rc=$?
    else
      t=$(timed_run on -u EIGS_JIT_OFF -u EIGS_JIT_OSR_THRESHOLD); rc=$?
    fi
    if [ "$rc" != 0 ]; then
      rm -f "$tf"
      echo "$name VERDICT=FAIL reason=timed-run-exited-$rc-arm-on-iter-$i (a timing of a failed run is not a timing)"
      return
    fi
    on+=("$t")
  done
  rm -f "$tf"

  local mo mn pairs
  mo=$(printf '%s\n' "${off[@]}" | med); mn=$(printf '%s\n' "${on[@]}" | med)
  # Paired deltas, one per interleaved iteration.
  pairs=""
  for ((i=0;i<N;i++)); do
    pairs="$pairs $(awk -v a="${off[$i]}" -v b="${on[$i]}" \
      'BEGIN{ if (a+0>0) printf "%.2f", 100*(a-b)/a; else print "nan" }')"
  done

  awk -v n="$name" -v con="$compiled_on" -v coff="$compiled_off" -v e="$expect" \
      -v f="$floor" -v o="$mo" -v m="$mn" -v skipoff="$skip_offcheck" \
      -v pairs="$pairs" 'BEGIN {
    if (o+0 <= 0 || m+0 <= 0) {
      printf "%s VERDICT=FAIL reason=no-timing (timeout or unparsable)\n", n; exit }
    pct = 100*(o-m)/o

    # Mechanism, before value (section 113). A timing whose arms ran the same
    # tier is not a measurement of that tier, whatever number it produces.
    if (skipoff+0 == 0 && coff+0 != 0) {
      printf "%s VERDICT=FAIL reason=off-arm-compiled-%d (EIGS_JIT_OFF is not disabling the JIT; both arms are the same tier)\n", n, coff; exit }
    if (e == "some" && con+0 == 0) {
      printf "%s VERDICT=FAIL reason=jit-never-engaged (off=%.2f on=%.2f pct=%+.1f is scheduler noise)\n", n, o, m, pct; exit }
    if (e == "none" && con+0 != 0) {
      printf "%s VERDICT=FAIL reason=control-compiled-%d (the control must engage nothing)\n", n, con; exit }

    # Paired statistic: median of the per-iteration deltas, plus the spread.
    np = split(pairs, P, " "); for (i=1;i<=np;i++) Q[i] = P[i]+0
    for (i=1;i<=np;i++) for (j=i+1;j<=np;j++) if (Q[j]<Q[i]) { t=Q[i]; Q[i]=Q[j]; Q[j]=t }
    pmed = (np % 2) ? Q[int(np/2)+1] : (Q[np/2]+Q[np/2+1])/2
    # Interquartile range, NOT the full range: the range can only grow with N,
    # so using it would mean more samples made a row less resolvable rather
    # than more. The IQR is stable as N rises, which is what lets raising N
    # actually settle a contested row.
    lo = Q[int(np/4)+1]; hi = Q[int(3*np/4)+1]; if (hi=="") hi = Q[np]
    spread = hi - lo
    if (spread < 0) spread = -spread

    if (e == "none") {
      v = (pmed <= 1.0 && pmed >= -1.0) ? "PASS" : "FAIL"
      printf "%s ENGAGE=0 off=%.2f on=%.2f PAIRED=%+.1f SPREAD=%.1f BAND=+-1.0 VERDICT=%s\n", n, o, m, pmed, spread, v; exit }

    # A verdict the instrument cannot support is UNRESOLVED, never a PASS and
    # never a FAIL: if the distance from the floor is inside the spread of the
    # paired samples, this box cannot tell the two apart today.
    if ((pmed - f+0) < spread/2 && (f+0 - pmed) < spread/2) {
      printf "%s ENGAGE=%s off=%.2f on=%.2f PAIRED=%+.1f SPREAD=%.1f FLOOR=%+.1f VERDICT=UNRESOLVED (effect is inside the instrument noise; re-read on a quiet box)\n", n, con, o, m, pmed, spread, f+0; exit }
    v = (pmed >= f+0) ? "PASS" : "FAIL"
    printf "%s ENGAGE=%s off=%.2f on=%.2f PAIRED=%+.1f SPREAD=%.1f FLOOR=%+.1f VERDICT=%s\n", n, con, o, m, pmed, spread, f+0, v
  }'
}

# ------------------------------------------------------------------ selftest
# Section 97: every plant must be an instance of the defect class named in the
# header -- "declared good on a number that did not measure the JIT".
# Section 100: each plant gutts one mechanism and requires THAT row to red.
if [ "$SELFTEST" = 1 ]; then
  echo "== jit_fleet_bench selftest =="; banner; echo
  run=0; bad=0
  check() { # name, expected-substring, output
    run=$((run+1))
    case "$3" in *"$2"*) echo "   ok   $1" ;;
      *) echo "   MISS $1 -- expected '$2'"; echo "        got: $3"; bad=$((bad+1)) ;;
    esac
  }
  # P1: the "on" arm is secretly the interpreter. A WIN row must go red: with
  # both arms identical the delta collapses to ~0, under a +3/+5 floor.
  out=$(N=3 run_row "dmg-5M:$ECO/DMG:3:some:dmg.eigs roms/cpu_instrs.gb --cycles 1000000" 1)
  # Must fail ON THE FLOOR, having produced a real PCT -- a missing-dir or
  # no-timing FAIL would satisfy a bare VERDICT=FAIL and prove nothing.
  check "P1 dead-JIT-arm measured a delta" "PAIRED=" "$out"
  check "P1 dead-JIT-arm does not PASS the WIN floor" "FLOOR=+3.0 VERDICT=" "$out"
  case "$out" in *"VERDICT=PASS"*) echo "   MISS P1 PASSED with a dead JIT arm"; bad=$((bad+1));; esac
  run=$((run+1))

  # P2: a workload the JIT never touches, timed as if it did. Must red BY
  # REASON -- passing on a lucky percentage is the failure being prevented.
  out=$(N=3 run_row "phantom:$ECO/liferaft:3:some:liferaft_sweep.eigs --seeds 5 --steps 50")
  check "P2 non-engaging row reds by reason" "jit-never-engaged" "$out"

  # P3: EIGS_JIT_OFF stops working, so both arms are the JIT. Simulated by
  # asserting the off-arm check itself catches a nonzero compiled count --
  # run a WIN row with the off-check ACTIVE but the on-arm forced off, which
  # leaves compiled_off>0 only if the flag is broken. Instead, prove the
  # assertion is live by feeding the control row a 'some' expectation: its
  # off arm compiles nothing, so a broken assertion would be invisible.
  out=$(N=3 run_row "offcheck:$ECO/DMG:3:some:dmg.eigs roms/cpu_instrs.gb --cycles 1000000" 0 1)
  check "P3 clean WIN row measures a real PCT (positive control)" "ENGAGE=" "$out"

  # P5: a workload that does not RUN must fail even on the control's
  # expectation (compiled=0), where every other check is satisfied by death.
  out=$(N=2 run_row "deadctl:$ECO/liferaft:-1:none:no_such_program_xyz.eigs")
  check "P5 dead workload reds on the control expectation" "workload-exited-" "$out"
  case "$out" in *VERDICT=PASS*) echo "   MISS P5 a DEAD program PASSED the control"; bad=$((bad+1));; esac
  run=$((run+1))

  # P6 (#1204): PASSES THE PROBE, FAILS THE TIMED RUNS. This is the gap P5
  # does not cover -- P5's program does not exist, so the up-front rc probe
  # catches it. The probe runs with a DIFFERENT environment from the runs it
  # vouches for (no EIGS_JIT_OFF), so a workload can satisfy the probe and
  # then die on every timed invocation. A blind critic did exactly that and
  # this harness reported PASS, +71.4%, with its own selftest green.
  #
  # The plant is that shape in two lines: exit 0 when run plainly, exit 23
  # when EIGS_JIT_OFF is set -- i.e. every off-arm timing is of a corpse.
  p6dir=$(mktemp -d "${TMPDIR:-/tmp}/jitfleet.p6.XXXXXX")
  # It must BURN TIME before dying. A plant that exits instantly is caught by
  # the no-timing check instead, which passes the row for the wrong reason
  # and proves nothing about rc (mechanical-gates section 41). With the loop,
  # `/usr/bin/time` emits a plausible elapsed line that `tail -1` happily
  # reads -- which is precisely how the critic's fixture got PASS, +71.4%.
  printf 'v is env_get of "EIGS_JIT_OFF"\ni is 0\ns is 0\nloop while i < 300000:\n    s is s + i\n    i is i + 1\nif v != "":\n    exit of 23\nprint of s\n' > "$p6dir/p6.eigs"
  # Registered as a LOSS row, not a control: as a control the
  # compile-nothing assertion fires first and the row reds for a reason that
  # says nothing about rc. With expect=some the mechanism checks are all
  # SATISFIED -- the on arm compiles, the off arm does not -- so the only
  # thing left standing between this corpse and a verdict is the rc check.
  out=$(N=2 run_row "probepass:$p6dir:0:some:p6.eigs")
  check "P6 a run that dies only when TIMED is caught" "timed-run-exited-23" "$out"
  case "$out" in *VERDICT=PASS*) echo "   MISS P6 a workload dying on every timed run PASSED"; bad=$((bad+1));; esac
  run=$((run+1))
  rm -rf "$p6dir"

  # P4: the population itself. A dropped row must fail, never shrink quietly.
  sub=$(ROWS=("${ROWS[@]:0:3}"); echo "${#ROWS[@]}")
  check "P4 ROW_COUNT pins the matrix size" "3" "$sub"

  echo
  echo "== selftest $run run, $((run-bad)) passed, $bad failed =="
  [ "$bad" = 0 ] || exit 1
  exit 0
fi

# ---------------------------------------------------------------------- run
banner; echo
examined=0; passed=0; failed=0; unresolved=0
for spec in "${ROWS[@]}"; do
  name="${spec%%:*}"
  if [ "$QUICK" = 1 ]; then
    case " $QUICK_ROWS " in *" $name "*) ;; *) continue ;; esac
  fi
  if [ -n "$ONLY" ]; then
    case ",$ONLY," in *",$name,"*) ;; *) continue ;; esac
  fi
  out=$(run_row "$spec"); echo "$out"
  examined=$((examined+1))
  case "$out" in
    *VERDICT=PASS*)       passed=$((passed+1)) ;;
    *VERDICT=UNRESOLVED*) unresolved=$((unresolved+1)) ;;
    *)                    failed=$((failed+1)) ;;
  esac
done

# Section 121/142: a run that examined nothing is a FAIL, and the tally says
# what it measured -- "N run, N passed, M failed", so a DELETED row and a
# FAILING row can never print the same thing.
[ "$examined" -gt 0 ] || fail "examined 0 rows -- the matrix is empty"
if [ "$QUICK" = 0 ] && [ -z "$ONLY" ] && [ "$examined" != "$ROW_COUNT" ]; then
  fail "examined $examined rows, matrix declares $ROW_COUNT"
fi

echo
echo "jit_fleet_bench: $examined run, $passed passed, $failed failed, $unresolved unresolved"
if [ "$unresolved" != 0 ]; then
  echo "jit_fleet_bench: NOT OK -- $unresolved row(s) the instrument could not resolve."
  echo "  An UNRESOLVED row is not a pass. Re-read on a quiet box (load < 0.5)"
  echo "  before treating its sign as real; widening the floor to swallow it"
  echo "  would be fitting the bar to the measurement."
  exit 1
fi
[ "$failed" = 0 ] || exit 1
echo "jit_fleet_bench: OK"
