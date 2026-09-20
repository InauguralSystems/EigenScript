#!/usr/bin/env bash
# consumer_acceptance.sh -- run every consumer's OWN acceptance command against
# a release candidate, and refuse to report success on a partial run.
#
# Milestone M1. The failures that bought it:
#   - a documented migration left three consumer suites unable to start (#1123)
#   - 93 commits sat beyond the released pin while all consumers stayed on it
#   - hq's hand-listed board never contained phugoid or polymethod, so two
#     live consumers were invisible to every release check
#   - primitives shipped for a consumer sat unused in that consumer's own code
#
# The rule that follows from those: a consumer that is MISSING, whose command
# cannot be found, or whose command is SKIPPED must fail the run. A release
# gate that can quietly examine fewer consumers than last time is the failure
# mode this whole file exists to prevent (mechanical-gates 15, 165).
#
#   tools/consumer_acceptance.sh plan            what would run, and coverage
#   tools/consumer_acceptance.sh run <BINARY>    run it, serially; write a record
#   tools/consumer_acceptance.sh --self-test     plant a fault, prove it fires
#
# Isolation (mechanical-gates §168): this script never mutates a sibling repo.
# Consumer commands run in the checkout as-is. Overrides, resolved per call:
#   CA_ECO      fixture or real ecosystem root (default: parent of this repo,
#               which is the sibling checkout only when this tree IS
#               EigenScriptEcosystem/EigenScript -- a git worktree must set
#               CA_ECO, otherwise the inventory is the worktree parent)
#   CA_TIMEOUT  per-consumer budget in seconds (default: 1800)
#   CA_RECORD   record path (default: a temp file; the path is printed)
#   CA_DROP_BEFORE  self-test only: after the inventory is snapshotted, remove
#                   this consumer's checkout. Honoured ONLY if $CA_ECO/.ca_fixture
#                   exists, so it cannot reach a real sibling.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

# Repos that pin this runtime but are deliberately NOT acceptance-gated. Each
# needs a reason -- an unexplained exclusion is how a consumer goes missing.
declare -A EXCLUDED=(
  [EigenAttention]="parked (see ecosystem-public notes)"
  [EigenAttic]="parked"
  [tmp]="scratch directory, not a repo"
  [legibility-experiment]="experiment, no acceptance suite"
  [awesome-eigenscript]="link list, nothing to run"
  [eigs-package-template]="template, exercised by the package tests upstream"
  [homebrew-eigenscript]="tap; exercised by the release workflow"
  [EigenOS]="deliberately unpinned sibling -- its own boot gates apply"
)

# Consumers whose CI does NOT use devcontainers/ci, so no runCmd exists to
# derive from: they build the runtime in a plain `run:` step. Declared here
# with the reason, because the alternative -- scraping arbitrary `run:` steps --
# would happily pick up a setup step and call it acceptance. Derive where
# derivable, declare where not, never silently skip.
declare -A DECLARED=(
  [eigen-edit]="bash tests/test_smoke.sh"
  [eigen-sheet]="bash tests/test_smoke.sh"
  [EigenMiniSat]="python3 -m unittest discover -s benchmarks -p 'test_*.py' -v"
  [EigenGauntlet]="bash tests/run.sh"
)

say() { printf '%s\n' "$*"; }

# Per-call: CA_ECO must be read HERE, not once at file load, so a self-test
# child with an override is not silently aimed at the real siblings.
resolve_eco() {
  if [ -n "${CA_ECO:-}" ]; then
    ECO="$(cd "$CA_ECO" && pwd)" || { say "consumer_acceptance: CA_ECO is not a directory: $CA_ECO"; exit 2; }
  else
    ECO="$(cd "$HERE/.." && pwd)"
  fi
}

# A repo counts as a consumer if it pins the runtime, in EITHER form: the
# devcontainer ARG, or a --branch clone in CI. Two forms, because using only
# the first is precisely how the hand-listed board lost two consumers.
pin_of() {
  local r="$1" p=""
  p="$(grep -ho 'ARG EIGS_REF=[^ ]*' "$ECO/$r/.devcontainer/Dockerfile" 2>/dev/null | head -1 | cut -d= -f2)"
  [ -n "$p" ] && { printf '%s' "$p"; return; }
  p="$(grep -rho -- '--branch v[0-9][0-9.]*' "$ECO/$r/.github/workflows/" 2>/dev/null | head -1 | awk '{print $2}')"
  printf '%s' "$p"
}

# The acceptance command is whatever CI actually runs -- derived, never typed,
# so it cannot drift from the thing the consumer considers passing.
accept_cmd_of() {
  local r="$1" f
  for f in "$ECO/$r"/.github/workflows/*.y*ml; do
    [ -f "$f" ] || continue
    python3 "$HERE/tools/_extract_runcmd.py" "$f" && return 0
  done
  return 1
}

# Scan ECO into GATE_* / SKIP_* arrays. Prints the plan listing iff $1=print.
# Does not print a verdict -- callers do. Diagnostics never go through stdout
# of a function whose result is captured (mechanical-gates: no $(( $(fn) ))).
# Globals: GATE_NAMES/PINS/CMDS/KINDS, SKIP_NAMES/PINS/REASONS, INVENTORY, GAPS.
scan_inventory() {
  local verbose=0
  [ "${1:-}" = print ] && verbose=1
  GATE_NAMES=(); GATE_PINS=(); GATE_CMDS=(); GATE_KINDS=()
  SKIP_NAMES=(); SKIP_PINS=(); SKIP_REASONS=()
  INVENTORY=0
  GAPS=0
  local r pin cmd d
  local nullglob_was=0
  shopt -q nullglob && nullglob_was=1
  shopt -s nullglob
  for d in "$ECO"/*/; do
    r="$(basename "$d")"
    [ "$r" = "EigenScript" ] && continue
    pin="$(pin_of "$r")"
    if [ -z "$pin" ]; then
      # Not a consumer. Only complain if it is also unexplained AND looks live.
      if [ "$verbose" -eq 1 ]; then
        [ -n "${EXCLUDED[$r]:-}" ] || [ ! -d "$d/.git" ] || say "  note   $r: pins nothing, not excluded -- not gated"
      fi
      continue
    fi
    if [ -n "${EXCLUDED[$r]:-}" ]; then
      SKIP_NAMES+=("$r")
      SKIP_PINS+=("$pin")
      SKIP_REASONS+=("${EXCLUDED[$r]}")
      if [ "$verbose" -eq 1 ]; then
        say "  skip   $r  ($pin) -- ${EXCLUDED[$r]}"
      fi
      continue
    fi
    cmd=""
    if cmd="$(accept_cmd_of "$r")"; then
      GATE_KINDS+=("derived")
    elif [ -n "${DECLARED[$r]:-}" ]; then
      cmd="${DECLARED[$r]}"
      GATE_KINDS+=("declared")
    else
      GATE_KINDS+=("gap")
      GAPS=$((GAPS + 1))
    fi
    GATE_NAMES+=("$r")
    GATE_PINS+=("$pin")
    GATE_CMDS+=("$cmd")
    INVENTORY=$((INVENTORY + 1))
    if [ "$verbose" -eq 1 ]; then
      local kind="${GATE_KINDS[$((INVENTORY - 1))]}"
      if [ "$kind" = declared ]; then
        say "  gate   $r  ($pin)  [declared -- CI has no runCmd to derive]"
        say "         $ $cmd"
      elif [ "$kind" = gap ]; then
        say "  GAP    $r  ($pin) -- pins the runtime but no acceptance command could be derived"
      else
        local lines
        lines="$(printf '%s' "$cmd" | wc -l)"
        say "  gate   $r  ($pin)"
        if [ "$lines" -gt 0 ]; then
          say "         $ $(printf '%s' "$cmd" | head -1 | cut -c1-100) ... (+$lines lines)"
        else
          say "         $ $(printf '%s' "$cmd" | cut -c1-110)"
        fi
      fi
    fi
  done
  if [ "$nullglob_was" -eq 0 ]; then
    shopt -u nullglob
  fi
}

inventory() {
  scan_inventory print
  say ""
  if [ "$INVENTORY" -eq 0 ]; then
    say "VERDICT: FAIL -- the inventory examined ZERO consumers"; FAILED=1; return
  fi
  if [ "$GAPS" -gt 0 ]; then
    say "VERDICT: FAIL -- $GAPS of $INVENTORY consumers have no derivable acceptance command"; FAILED=1; return
  fi
  say "VERDICT: PASS -- $INVENTORY consumers, every one with a derived acceptance command"
}

# --- run mode -------------------------------------------------------------

TMO_BIN=""
BUDGET=1800
KILL_AFTER=10
SHIM=""
WORK=""
RECORD=""
RECORD_FINISHED=0
EXAMINED=0
CAND_ABS=""
CAND_VER=""
RESOLVED=""
RUN_RC=1
ANY_BAD=0

probe_timeout() {
  TMO_BIN=""
  if command -v timeout >/dev/null 2>&1; then
    TMO_BIN=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    TMO_BIN=gtimeout
  fi
}

abs_path() {
  local d b
  d="$(cd "$(dirname "$1")" && pwd)" || return 1
  b="$(basename "$1")"
  printf '%s/%s' "$d" "$b"
}

# EXIT/INT/TERM: a record that never got a footer is INCOMPLETE. Guard every
# expansion -- under set -u a trap abort skips the rest of cleanup.
finish_incomplete() {
  [ "${RECORD_FINISHED:-0}" -eq 1 ] && return
  [ -n "${RECORD:-}" ] && [ -f "$RECORD" ] || return
  {
    printf 'status=INCOMPLETE\n'
    printf 'examined=%s\n' "${EXAMINED:-0}"
    printf 'inventory=%s examined=%s\n' "${INVENTORY:-0}" "${EXAMINED:-0}"
    printf 'VERDICT: INCOMPLETE\n'
  } >> "$RECORD"
  RECORD_FINISHED=1
}

run_cleanup() {
  finish_incomplete
  if [ -n "${WORK:-}" ] && [ -d "${WORK:-}" ]; then
    rm -rf "$WORK"
  fi
}

# Signal only this process's direct children (the in-flight timeout). Never
# pkill -- a pattern match kills the invoking shell (test-suite rule).
kill_run_children() {
  local p
  for p in $(ps -eo pid= -o ppid= | awk -v me="$$" '$2+0 == me+0 { print $1 }'); do
    kill -TERM "$p" 2>/dev/null || true
  done
}

install_run_traps() {
  trap 'kill_run_children; run_cleanup; exit 2' INT TERM
  trap 'run_cleanup' EXIT
}

write_record_header() {
  {
    printf '# consumer_acceptance record\n'
    printf 'candidate_path=%s\n' "$CAND_ABS"
    printf 'candidate_version=%s\n' "$CAND_VER"
    printf 'eigenscript_resolved=%s\n' "$RESOLVED"
    printf 'inventory=%s\n' "$INVENTORY"
    printf 'examined=PENDING\n'
    printf 'status=RUNNING\n'
    printf '# row|name|pin|verdict|rc|duration_s\n'
  } > "$RECORD"
}

write_record_footer() {
  local verdict="$1" status="$2" tmp line
  tmp="$(mktemp "${TMPDIR:-/tmp}/ca-rec-rewrite.XXXXXX")"
  # A finished record's HEADER must state inventory=N examined=M. PENDING
  # stays only on an interrupted file that never reached this function.
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      examined=PENDING) printf 'examined=%s\n' "$EXAMINED" ;;
      status=RUNNING)   printf 'status=%s\n' "$status" ;;
      *)                printf '%s\n' "$line" ;;
    esac
  done < "$RECORD" > "$tmp"
  {
    printf 'inventory=%s examined=%s\n' "$INVENTORY" "$EXAMINED"
    printf 'status=%s\n' "$status"
    printf 'VERDICT: %s\n' "$verdict"
  } >> "$tmp"
  mv "$tmp" "$RECORD"
  RECORD_FINISHED=1
}

append_row() {
  # $1 name $2 pin $3 verdict $4 rc $5 duration
  printf 'row|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$RECORD"
}

append_skip() {
  printf 'skip|%s|%s|%s\n' "$1" "$2" "$3" >> "$RECORD"
}

# Run one consumer command. Sets LAST_VERDICT, LAST_RC, LAST_DUR.
# Never prints -- the caller reports.
LAST_VERDICT=""
LAST_RC=""
LAST_DUR=""

run_one() {
  local name="$1" pin="$2" cmd="$3"
  local repo="$ECO/$name" log cmdfile start end
  LAST_VERDICT=""
  LAST_RC="-"
  LAST_DUR="0"

  if [ ! -d "$repo" ]; then
    LAST_VERDICT=UNRUNNABLE
    LAST_RC="-"
    LAST_DUR="0"
    return
  fi
  if [ -z "$cmd" ]; then
    LAST_VERDICT=UNRUNNABLE
    LAST_RC="-"
    LAST_DUR="0"
    return
  fi

  cmdfile="$WORK/cmds/$name.sh"
  log="$WORK/logs/$name.log"
  mkdir -p "$WORK/cmds" "$WORK/logs"
  printf '%s\n' "$cmd" > "$cmdfile"

  start="$(date +%s)"
  (
    cd "$repo" || exit 125
    export PATH="$SHIM:$PATH"
    export EIGS=eigenscript
    export EIGENSCRIPT=eigenscript
    exec "$TMO_BIN" --kill-after="$KILL_AFTER" "$BUDGET" bash "$cmdfile"
  ) < /dev/null > "$log" 2>&1
  LAST_RC=$?
  end="$(date +%s)"
  LAST_DUR=$((end - start))
  if [ "$LAST_DUR" -lt 0 ]; then LAST_DUR=0; fi

  case "$LAST_RC" in
    0)   LAST_VERDICT=PASS ;;
    124) LAST_VERDICT=HANG ;;
    137) LAST_VERDICT=KILLED ;;
    125) LAST_VERDICT=UNRUNNABLE ;;
    *)   LAST_VERDICT=FAIL ;;
  esac
}

run_mode() {
  local cand="${1:-}"
  resolve_eco
  probe_timeout
  BUDGET="${CA_TIMEOUT:-1800}"
  KILL_AFTER="${CA_KILL_AFTER:-10}"

  case "$BUDGET" in
    ''|*[!0-9]*|0) say "consumer_acceptance: CA_TIMEOUT must be an integer >= 1 (got ${CA_TIMEOUT:-})"; exit 2 ;;
  esac

  if [ -z "$cand" ]; then
    say "usage: $0 run <CANDIDATE_BINARY>"
    exit 2
  fi
  if [ ! -f "$cand" ] || [ ! -x "$cand" ]; then
    say "consumer_acceptance: candidate is not an executable file: $cand"
    exit 2
  fi
  CAND_ABS="$(abs_path "$cand")" || { say "consumer_acceptance: cannot resolve candidate path: $cand"; exit 2; }

  if [ -z "$TMO_BIN" ]; then
    say "consumer_acceptance: no timeout(1)/gtimeout(1) on PATH -- refusing to run unbounded"
    exit 2
  fi

  scan_inventory

  # Self-test plant B: drop a snapshotted consumer's checkout. The .ca_fixture
  # marker is the only thing that unlocks this, so a stray env var cannot
  # delete a sibling (mechanical-gates §168).
  if [ -n "${CA_DROP_BEFORE:-}" ] && [ -f "$ECO/.ca_fixture" ]; then
    rm -rf "$ECO/$CA_DROP_BEFORE"
  fi

  WORK="$(mktemp -d "${TMPDIR:-/tmp}/ca-run.XXXXXX")"
  SHIM="$WORK/bin"
  mkdir -p "$SHIM"
  ln -s "$CAND_ABS" "$SHIM/eigenscript"
  export PATH="$SHIM:$PATH"
  export EIGS=eigenscript
  export EIGENSCRIPT=eigenscript
  RESOLVED="$(command -v eigenscript)"
  CAND_VER="$("$CAND_ABS" --version 2>&1 | head -1 || true)"
  CAND_VER="${CAND_VER:-}"

  if [ -n "${CA_RECORD:-}" ]; then
    RECORD="$CA_RECORD"
  else
    RECORD="$(mktemp "${TMPDIR:-/tmp}/ca-record.XXXXXX")"
  fi
  : > "$RECORD"

  install_run_traps
  write_record_header

  say "consumer_acceptance run  bash=$BASH_VERSION  uname=$(uname -s)  timeout=$TMO_BIN  budget=${BUDGET}s"
  say "record: $RECORD"
  say "candidate: $CAND_ABS"
  say "candidate_version: $CAND_VER"
  say "eigenscript_resolved: $RESOLVED"
  say "inventory=$INVENTORY examined=PENDING"

  local i name pin cmd verdict
  i=0
  while [ "$i" -lt "${#SKIP_NAMES[@]}" ]; do
    append_skip "${SKIP_NAMES[$i]}" "${SKIP_PINS[$i]}" "${SKIP_REASONS[$i]}"
    say "  SKIP       ${SKIP_NAMES[$i]}  pin=${SKIP_PINS[$i]}  -- ${SKIP_REASONS[$i]}"
    i=$((i + 1))
  done

  EXAMINED=0
  ANY_BAD=0
  i=0
  while [ "$i" -lt "$INVENTORY" ]; do
    name="${GATE_NAMES[$i]}"
    pin="${GATE_PINS[$i]}"
    cmd="${GATE_CMDS[$i]}"
    run_one "$name" "$pin" "$cmd"
    verdict="$LAST_VERDICT"
    append_row "$name" "$pin" "$verdict" "$LAST_RC" "$LAST_DUR"
    EXAMINED=$((EXAMINED + 1))
    say "  $verdict  $name  pin=$pin rc=$LAST_RC ${LAST_DUR}s"
    if [ "$verdict" != PASS ]; then
      ANY_BAD=1
    fi
    i=$((i + 1))
  done

  local final="FAIL"
  RUN_RC=1
  if [ "$INVENTORY" -eq 0 ] || [ "$EXAMINED" -ne "$INVENTORY" ]; then
    final=FAIL
    RUN_RC=1
    ANY_BAD=1
  elif [ "$ANY_BAD" -eq 0 ]; then
    final=PASS
    RUN_RC=0
  else
    final=FAIL
    RUN_RC=1
  fi

  write_record_footer "$final" COMPLETE
  say "inventory=$INVENTORY examined=$EXAMINED"
  say "VERDICT: $final"
  # EXIT trap must not rewrite the footer as INCOMPLETE.
  RECORD_FINISHED=1
  exit "$RUN_RC"
}

# --- self-test ------------------------------------------------------------

# Tiny fake consumers under a fixture ECO. Never the real 16.
mk_consumer() {
  local eco="$1" name="$2" runcmd="${3:-}"
  mkdir -p "$eco/$name/.devcontainer" "$eco/$name/.git"
  printf 'ARG EIGS_REF=v0.43.0\n' > "$eco/$name/.devcontainer/Dockerfile"
  if [ -n "$runcmd" ]; then
    mkdir -p "$eco/$name/.github/workflows"
    printf 'runCmd: %s\n' "$runcmd" > "$eco/$name/.github/workflows/ci.yml"
  fi
}

mk_stub() {
  local path="$1" rc="$2"
  printf '%s\n' "#!/bin/sh" "if [ \"\${1:-}\" = --version ]; then echo 'eigenscript stub'; exit $rc; fi" "exit $rc" > "$path"
  chmod +x "$path"
}

# $1 plant name  $2 0=FIRES 1=SILENT  $3 detail
plant_line() {
  local name="$1" st="$2" detail="${3:-}"
  if [ "$st" -eq 0 ]; then
    say "plant $name: FIRES${detail:+ -- $detail}"
  else
    say "plant $name: SILENT${detail:+ -- $detail}"
    ST_FAIL=1
  fi
}

selftest() {
  local st_root rec out rc pid
  ST_FAIL=0
  st_root="$(mktemp -d "${TMPDIR:-/tmp}/ca-st.XXXXXX")"
  # Subshell-safe cleanup: do not cd into st_root in the same command that
  # deletes it.
  trap 'rm -rf "$st_root"' EXIT

  # --- plan plant (existing): an ungated consumer must FAIL the plan.
  # Isolated under CA_ECO so it cannot touch a sibling (mechanical-gates §168).
  local plan_eco="$st_root/plan-eco"
  mkdir -p "$plan_eco"
  mk_consumer "$plan_eco" zz-planted-consumer ""
  out="$(CA_ECO="$plan_eco" "$0" plan 2>&1)" || true
  if printf '%s' "$out" | grep -q "GAP    zz-planted-consumer"; then
    say "SELF-TEST: PASS -- an ungated consumer fails the plan"
    plant_line "plan-ungated" 0 "GAP named zz-planted-consumer"
  else
    say "SELF-TEST: FAIL -- a planted ungated consumer did not fail the plan"
    printf '%s\n' "$out" | tail -5
    plant_line "plan-ungated" 1 "no GAP line"
  fi

  # --- control: two passing fake consumers, stub exits 0.
  local good_eco="$st_root/good-eco"
  mkdir -p "$good_eco"
  printf 'fixture\n' > "$good_eco/.ca_fixture"
  mk_consumer "$good_eco" good_a "eigenscript"
  mk_consumer "$good_eco" good_b '$EIGS'
  mk_stub "$st_root/stub-ok" 0
  rec="$st_root/good.record"
  out="$(CA_ECO="$good_eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$0" run "$st_root/stub-ok" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ] \
     && grep -q 'VERDICT: PASS' "$rec" \
     && grep -q 'inventory=2 examined=2' "$rec" \
     && grep -q 'row|good_a|v0.43.0|PASS|' "$rec" \
     && grep -q 'row|good_b|v0.43.0|PASS|' "$rec"; then
    plant_line "control honest-good" 0 "VERDICT: PASS inventory=2 examined=2"
  else
    plant_line "control honest-good" 1 "rc=$rc record=$(tail -5 "$rec" 2>/dev/null | tr '\n' ' ')"
  fi

  # Plan on the same honest fixture must still PASS (plan mode unchanged).
  out="$(CA_ECO="$good_eco" "$0" plan 2>&1)" || true
  if printf '%s' "$out" | grep -q 'VERDICT: PASS -- 2 consumers'; then
    plant_line "plan-control" 0 "plan still PASSes a 2-consumer fixture"
  else
    plant_line "plan-control" 1 "plan did not PASS the honest fixture"
  fi

  # SKIP rows exist ONLY for EXCLUDED names, and they are not examined.
  local skip_eco="$st_root/skip-eco"
  mkdir -p "$skip_eco"
  printf 'fixture\n' > "$skip_eco/.ca_fixture"
  mk_consumer "$skip_eco" keep "eigenscript"
  mk_consumer "$skip_eco" tmp "eigenscript"
  rec="$st_root/skip.record"
  out="$(CA_ECO="$skip_eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$0" run "$st_root/stub-ok" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ] \
     && grep -q 'VERDICT: PASS' "$rec" \
     && grep -q 'inventory=1 examined=1' "$rec" \
     && grep -q '^skip|tmp|' "$rec" \
     && grep -q 'row|keep|v0.43.0|PASS|' "$rec"; then
    plant_line "skip-excluded" 0 "tmp SKIP not examined, keep PASS, inventory=1 examined=1"
  else
    plant_line "skip-excluded" 1 "rc=$rc"
  fi

  # --- A: broken candidate, every row FAIL, verdict FAIL.
  local a_eco="$st_root/a-eco"
  mkdir -p "$a_eco"
  printf 'fixture\n' > "$a_eco/.ca_fixture"
  mk_consumer "$a_eco" a_one "eigenscript"
  mk_consumer "$a_eco" a_two "eigenscript"
  mk_stub "$st_root/stub-bad" 1
  rec="$st_root/a.record"
  out="$(CA_ECO="$a_eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$0" run "$st_root/stub-bad" 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ] \
     && grep -q 'VERDICT: FAIL' "$rec" \
     && grep -q 'row|a_one|v0.43.0|FAIL|' "$rec" \
     && grep -q 'row|a_two|v0.43.0|FAIL|' "$rec" \
     && ! grep -q '|PASS|' "$rec"; then
    plant_line "A broken-candidate" 0 "every row FAIL, VERDICT: FAIL"
  else
    plant_line "A broken-candidate" 1 "rc=$rc"
  fi

  # --- B: shrinkage -- present at plan time, removed before its turn.
  local b_eco="$st_root/b-eco"
  mkdir -p "$b_eco"
  printf 'fixture\n' > "$b_eco/.ca_fixture"
  mk_consumer "$b_eco" keep "eigenscript"
  mk_consumer "$b_eco" victim "eigenscript"
  rec="$st_root/b.record"
  out="$(CA_ECO="$b_eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_DROP_BEFORE=victim CA_RECORD="$rec" "$0" run "$st_root/stub-ok" 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ] \
     && grep -q 'VERDICT: FAIL' "$rec" \
     && grep -q 'row|victim|v0.43.0|UNRUNNABLE|' "$rec" \
     && grep -q 'inventory=2 examined=2' "$rec"; then
    plant_line "B shrinkage" 0 "UNRUNNABLE victim, examined=2 inventory=2, VERDICT: FAIL"
  else
    plant_line "B shrinkage" 1 "rc=$rc"
  fi

  # --- C: hang -- sleep past budget; HANG by name; run continues.
  local c_eco="$st_root/c-eco"
  mkdir -p "$c_eco"
  printf 'fixture\n' > "$c_eco/.ca_fixture"
  # Names force glob order: the hang MUST run first so "continues to the next
  # consumer" is observable, not vacuously true of a last-place hang.
  mk_consumer "$c_eco" aaa_sleep "sleep 30"
  mk_consumer "$c_eco" zzz_pass "eigenscript"
  rec="$st_root/c.record"
  out="$(CA_ECO="$c_eco" CA_TIMEOUT=1 CA_KILL_AFTER=1 CA_RECORD="$rec" "$0" run "$st_root/stub-ok" 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ] \
     && grep -q 'VERDICT: FAIL' "$rec" \
     && grep -q 'row|aaa_sleep|v0.43.0|HANG|124|' "$rec" \
     && grep -q 'row|zzz_pass|v0.43.0|PASS|' "$rec"; then
    plant_line "C hang" 0 "HANG aaa_sleep rc=124, zzz_pass still PASS, VERDICT: FAIL"
  else
    plant_line "C hang" 1 "rc=$rc record=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  fi

  # --- C2: SIGKILL is KILLED by name, never folded into FAIL.
  local k_eco="$st_root/k-eco"
  mkdir -p "$k_eco"
  printf 'fixture\n' > "$k_eco/.ca_fixture"
  mk_consumer "$k_eco" aaa_kill 'kill -9 $$'
  mk_consumer "$k_eco" zzz_ok "eigenscript"
  rec="$st_root/k.record"
  out="$(CA_ECO="$k_eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$0" run "$st_root/stub-ok" 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ] \
     && grep -q 'VERDICT: FAIL' "$rec" \
     && grep -q 'row|aaa_kill|v0.43.0|KILLED|137|' "$rec" \
     && grep -q 'row|zzz_ok|v0.43.0|PASS|' "$rec"; then
    plant_line "C2 killed" 0 "KILLED aaa_kill rc=137, zzz_ok still PASS"
  else
    plant_line "C2 killed" 1 "rc=$rc record=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  fi

  # --- D: interruption -- SIGTERM mid-wave; record INCOMPLETE; exit 2.
  local d_eco="$st_root/d-eco"
  mkdir -p "$d_eco"
  printf 'fixture\n' > "$d_eco/.ca_fixture"
  mk_consumer "$d_eco" aaa_block "sleep 30"
  mk_consumer "$d_eco" zzz_after "eigenscript"
  rec="$st_root/d.record"
  CA_ECO="$d_eco" CA_TIMEOUT=20 CA_KILL_AFTER=1 CA_RECORD="$rec" "$0" run "$st_root/stub-ok" >/dev/null 2>&1 &
  pid=$!
  # Wait until the record exists and the wave has started, then signal.
  local waited=0
  while [ "$waited" -lt 20 ]; do
    if [ -f "$rec" ] && grep -q 'status=RUNNING' "$rec" 2>/dev/null; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  sleep 1
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid"
  rc=$?
  if [ "$rc" -eq 2 ] \
     && grep -q 'VERDICT: INCOMPLETE' "$rec" \
     && grep -q 'status=INCOMPLETE' "$rec"; then
    plant_line "D interruption" 0 "record INCOMPLETE, exit 2"
  else
    plant_line "D interruption" 1 "rc=$rc record=$(tail -6 "$rec" 2>/dev/null | tr '\n' ' ')"
  fi

  if [ "$ST_FAIL" -ne 0 ]; then
    say "SELF-TEST: FAIL -- one or more plants SILENT"
    exit 1
  fi
  say "SELF-TEST: PASS -- run-mode plants FIRE and the honest control passes"
  exit 0
}

case "${1:-plan}" in
  plan)
    resolve_eco
    say "consumer acceptance -- plan"; say ""; inventory ;;
  run)
    run_mode "${2:-}" ;;
  --self-test)
    selftest ;;
  *) say "usage: $0 [plan|run|--self-test]"; exit 2 ;;
esac

exit "$FAILED"
