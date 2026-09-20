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
#               CA_ECO, otherwise the inventory is the worktree parent). The
#               resolved root is printed in the record header as eco_root=.
#   CA_TIMEOUT  per-consumer budget in seconds (default: 1800). Also bounds
#               the candidate --version probe.
#   CA_RECORD   record path (default: a temp file; the path is printed)
#   CA_DROP_BEFORE  self-test only: after the inventory is snapshotted, remove
#                   this consumer's checkout. Honoured ONLY if $CA_ECO/.ca_fixture
#                   exists, so it cannot reach a real sibling.
#   CA_FAULT    self-test only, same .ca_fixture gate:
#                 stop_after=N       break the wave after N examined rows
#                                    (the completed-record path for
#                                    examined < inventory; interrupt is plant D)
#                 empty_skip_reason  append a SKIP row with an empty reason
#
# Record lifecycle (fail-closed):
#   A previous file at the record path is moved aside before the wave.
#   The record is created INCOMPLETE (run_id + timestamp + eco_root) and
#   INT/TERM/HUP traps are installed BEFORE anything from the candidate
#   executes -- including --version, which runs under the same timeout.
#   VERDICT: PASS is printed only after the final record is written to a
#   temp path in the same directory and renamed into place. A write/rename
#   failure is FAIL, exit 1, and stdout says why.
#
# Consumers run as a background job (setsid + timeout, wait in this shell)
# so a trap can kill the in-flight process group without waiting out the
# consumer budget. Block bodies run under bash -e -o pipefail -c.
#
# examined != inventory on a COMPLETED record is unreachable without a
# broken loop: the production path that stops early is an interrupt, and
# that writes INCOMPLETE (plant D). The completed-record clause is planted
# by CA_FAULT=stop_after=N under .ca_fixture (plant early-stop). The
# honest control also pins inventory=2 examined=2 by grep.
#
# CA-GUARD: comments name the six checks the self-test guts in isolation.
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
  # CA-GUARD:plan-gap
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
RECORD_WRITE_ERR=""
EXAMINED=0
CAND_ABS=""
CAND_VER=""
RESOLVED=""
RUN_RC=1
ANY_BAD=0
SKIP_MISSING_REASON=0
CA_INFLIGHT_PID=""
RUN_ID=""
STARTED=""
PROBE_RC="-"

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

# One printf, so a mutation that appends text is a single site. Used for both
# the record footer and stdout -- PASS is exact-match grepped in the self-test.
verdict_line() {
  # CA-GUARD:exact-verdict
  printf 'VERDICT: %s\n' "$1"
}

fixture_fault() {
  [ -f "${ECO:-}/.ca_fixture" ] || return 1
  [ -n "${CA_FAULT:-}" ] || return 1
  return 0
}

# EXIT/INT/TERM/HUP: a record that never got a footer is INCOMPLETE. Guard
# every expansion -- under set -u a trap abort skips the rest of cleanup.
finish_incomplete() {
  [ "${RECORD_FINISHED:-0}" -eq 1 ] && return
  [ -n "${RECORD:-}" ] && [ -f "$RECORD" ] || return
  {
    printf 'status=INCOMPLETE\n'
    printf 'examined=%s\n' "${EXAMINED:-0}"
    printf 'inventory=%s examined=%s\n' "${INVENTORY:-0}" "${EXAMINED:-0}"
    verdict_line INCOMPLETE
  } >> "$RECORD" 2>/dev/null || true
  RECORD_FINISHED=1
}

kill_inflight() {
  local p="${CA_INFLIGHT_PID:-}"
  [ -n "$p" ] || return 0
  # Process-group first so timeout's grandchildren die; fall back to the pid
  # if this child is not a group leader (no setsid on the host).
  kill -TERM -- "-$p" 2>/dev/null || kill -TERM "$p" 2>/dev/null || true
  kill -KILL -- "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null || true
}

run_cleanup() {
  kill_inflight
  finish_incomplete
  if [ -n "${WORK:-}" ] && [ -d "${WORK:-}" ]; then
    rm -rf "$WORK"
  fi
}

install_run_traps() {
  trap 'kill_inflight; run_cleanup; exit 2' INT TERM HUP
  trap 'run_cleanup' EXIT
}

# Write stdin onto $RECORD via a same-directory temp + rename. PASS is never
# emitted until this succeeds for the footer.
atomic_replace_record() {
  local dir tmp
  RECORD_WRITE_ERR=""
  dir="$(dirname "$RECORD")"
  tmp="$dir/.$(basename "$RECORD").tmp.$$"
  if ! cat > "$tmp" 2>/dev/null; then
    RECORD_WRITE_ERR="cannot write record temp at $tmp"
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  if ! mv "$tmp" "$RECORD" 2>/dev/null; then
    RECORD_WRITE_ERR="cannot rename record temp onto $RECORD"
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  return 0
}

stash_previous_record() {
  [ -e "$RECORD" ] || return 0
  local aside n
  aside="${RECORD}.prev"
  n=1
  while [ -e "$aside" ]; do
    aside="${RECORD}.prev.$n"
    n=$((n + 1))
  done
  mv "$RECORD" "$aside" 2>/dev/null || return 1
  return 0
}

write_record_header() {
  {
    printf '# consumer_acceptance record\n'
    printf 'run_id=%s\n' "$RUN_ID"
    printf 'started=%s\n' "$STARTED"
    printf 'eco_root=%s\n' "$ECO"
    printf 'block_shell=bash -e -o pipefail -c\n'
    printf 'candidate_path=%s\n' "$CAND_ABS"
    printf 'candidate_version=PENDING\n'
    printf 'eigenscript_resolved=%s\n' "${RESOLVED:-PENDING}"
    printf 'inventory=%s\n' "$INVENTORY"
    printf 'examined=PENDING\n'
    printf 'status=INCOMPLETE\n'
    printf '# row|name|pin|verdict|rc|duration_s\n'
  } | atomic_replace_record
}

write_record_footer() {
  local verdict="$1" status="$2" tmp line
  tmp="$(dirname "$RECORD")/.$(basename "$RECORD").rewrite.$$"
  if ! {
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        examined=PENDING)          printf 'examined=%s\n' "$EXAMINED" ;;
        status=INCOMPLETE|status=RUNNING) printf 'status=%s\n' "$status" ;;
        candidate_version=PENDING) printf 'candidate_version=%s\n' "$CAND_VER" ;;
        eigenscript_resolved=PENDING) printf 'eigenscript_resolved=%s\n' "$RESOLVED" ;;
        *)                         printf '%s\n' "$line" ;;
      esac
    done < "$RECORD"
    printf 'probe_rc=%s\n' "$PROBE_RC"
    printf 'inventory=%s examined=%s\n' "$INVENTORY" "$EXAMINED"
    printf 'status=%s\n' "$status"
    verdict_line "$verdict"
  } > "$tmp" 2>/dev/null; then
    RECORD_WRITE_ERR="cannot write record rewrite at $tmp"
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  if ! mv "$tmp" "$RECORD" 2>/dev/null; then
    RECORD_WRITE_ERR="cannot rename record rewrite onto $RECORD"
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  RECORD_FINISHED=1
  return 0
}

append_row() {
  printf 'row|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" >> "$RECORD" 2>/dev/null || {
    RECORD_WRITE_ERR="cannot append row to $RECORD"
    ANY_BAD=1
  }
}

append_skip() {
  # CA-GUARD:skip-reason
  if [ -z "$3" ]; then
    SKIP_MISSING_REASON=1
    ANY_BAD=1
  fi
  printf 'skip|%s|%s|%s\n' "$1" "$2" "$3" >> "$RECORD" 2>/dev/null || true
}

# Bounded background job: wait in THIS shell so INT/TERM/HUP can fire and
# kill the process group without waiting out the consumer budget.
run_bounded() {
  local log="$1"
  shift
  CA_INFLIGHT_PID=""
  if command -v setsid >/dev/null 2>&1; then
    setsid "$TMO_BIN" --kill-after="$KILL_AFTER" "$BUDGET" "$@" < /dev/null > "$log" 2>&1 &
  else
    "$TMO_BIN" --kill-after="$KILL_AFTER" "$BUDGET" "$@" < /dev/null > "$log" 2>&1 &
  fi
  CA_INFLIGHT_PID=$!
  wait "$CA_INFLIGHT_PID"
  LAST_RC=$?
  CA_INFLIGHT_PID=""
}

LAST_VERDICT=""
LAST_RC=""
LAST_DUR=""

run_one() {
  local name="$1" pin="$2" cmd="$3"
  local repo="$ECO/$name" log start end cd_cmd
  LAST_VERDICT=""
  LAST_RC="-"
  LAST_DUR="0"

  if [ ! -d "$repo" ]; then
    LAST_VERDICT=UNRUNNABLE
    LAST_RC="-"
    LAST_DUR="0"
    return
  fi
  # CA-GUARD:missing-command
  if [ -z "$cmd" ]; then
    LAST_VERDICT=UNRUNNABLE
    LAST_RC="-"
    LAST_DUR="0"
    return
  fi

  log="$WORK/logs/$name.log"
  mkdir -p "$WORK/logs"

  cd_cmd="$(printf 'export PATH=%q:"$PATH"\nexport EIGS=eigenscript\nexport EIGENSCRIPT=eigenscript\ncd %q || exit 125\n%s\n' "$SHIM" "$repo" "$cmd")"

  start="$(date +%s)"
  run_bounded "$log" bash -e -o pipefail -c "$cd_cmd"
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

fail_closed() {
  local why="$1"
  say "consumer_acceptance: $why"
  if [ -n "${RECORD:-}" ] && [ -f "${RECORD:-}" ]; then
    write_record_footer FAIL COMPLETE || true
  fi
  verdict_line FAIL
  RECORD_FINISHED=1
  exit 1
}

finalize_run() {
  local final=FAIL
  RUN_RC=1
  # CA-GUARD:nonempty-inventory
  if [ "$INVENTORY" -eq 0 ]; then
    final=FAIL
    RUN_RC=1
  # CA-GUARD:examined-eq-inventory
  elif [ "$EXAMINED" -ne "$INVENTORY" ]; then
    final=FAIL
    RUN_RC=1
  elif [ "${SKIP_MISSING_REASON:-0}" -ne 0 ]; then
    final=FAIL
    RUN_RC=1
  elif [ "$ANY_BAD" -eq 0 ]; then
    final=PASS
    RUN_RC=0
  else
    final=FAIL
    RUN_RC=1
  fi

  if ! write_record_footer "$final" COMPLETE; then
    say "consumer_acceptance: failed to write final record: ${RECORD_WRITE_ERR:-unknown}"
    verdict_line FAIL
    RECORD_FINISHED=1
    exit 1
  fi
  say "inventory=$INVENTORY examined=$EXAMINED"
  verdict_line "$final"
  RECORD_FINISHED=1
  exit "$RUN_RC"
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

  if fixture_fault && [ "${CA_FAULT:-}" = "empty_skip_reason" ]; then
    SKIP_NAMES+=("planted_empty_skip")
    SKIP_PINS+=("v0.43.0")
    SKIP_REASONS+=("")
  fi

  WORK="$(mktemp -d "${TMPDIR:-/tmp}/ca-run.XXXXXX")"
  SHIM="$WORK/bin"
  mkdir -p "$SHIM"
  ln -s "$CAND_ABS" "$SHIM/eigenscript"
  RESOLVED="$SHIM/eigenscript"

  RUN_ID="$(date +%s).$$.${RANDOM:-0}"
  STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)"

  if [ -n "${CA_RECORD:-}" ]; then
    RECORD="$CA_RECORD"
  else
    RECORD="$(mktemp "${TMPDIR:-/tmp}/ca-record.XXXXXX")"
  fi

  # Stale PASS from a previous run must not be this run's record: move it
  # aside first. Traps + INCOMPLETE file exist before any candidate exec.
  stash_previous_record || true
  install_run_traps
  if ! write_record_header; then
    fail_closed "cannot initialise record at $RECORD: ${RECORD_WRITE_ERR:-unknown}"
  fi

  say "consumer_acceptance run  bash=$BASH_VERSION  uname=$(uname -s)  timeout=$TMO_BIN  budget=${BUDGET}s"
  say "record: $RECORD"
  say "run_id: $RUN_ID"
  say "eco_root: $ECO"
  say "candidate: $CAND_ABS"
  say "eigenscript_resolved: $RESOLVED"
  say "inventory=$INVENTORY examined=PENDING"

  # --version is a candidate exec: same timeout, same background wait.
  local probe_log
  probe_log="$WORK/probe.log"
  run_bounded "$probe_log" "$CAND_ABS" --version
  PROBE_RC="$LAST_RC"
  if [ "$PROBE_RC" -ne 0 ]; then
    CAND_VER=""
    say "candidate_version: UNRUNNABLE (probe rc=$PROBE_RC)"
    ANY_BAD=1
    finalize_run
  fi
  CAND_VER="$(head -1 "$probe_log" 2>/dev/null || true)"
  CAND_VER="${CAND_VER:-}"
  say "candidate_version: $CAND_VER"

  local i name pin cmd verdict STOP_AFTER
  STOP_AFTER=0
  if fixture_fault; then
    case "${CA_FAULT:-}" in
      stop_after=*)
        STOP_AFTER="${CA_FAULT#stop_after=}"
        case "$STOP_AFTER" in
          ''|*[!0-9]*) STOP_AFTER=0 ;;
        esac
        ;;
    esac
  fi

  i=0
  while [ "$i" -lt "${#SKIP_NAMES[@]}" ]; do
    append_skip "${SKIP_NAMES[$i]}" "${SKIP_PINS[$i]}" "${SKIP_REASONS[$i]}"
    say "  SKIP       ${SKIP_NAMES[$i]}  pin=${SKIP_PINS[$i]}  -- ${SKIP_REASONS[$i]}"
    i=$((i + 1))
  done

  EXAMINED=0
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
    if [ "$STOP_AFTER" -gt 0 ] && [ "$EXAMINED" -ge "$STOP_AFTER" ]; then
      break
    fi
    i=$((i + 1))
  done

  finalize_run
}

# --- self-test ------------------------------------------------------------

mk_consumer() {
  local eco="$1" name="$2" runcmd="${3:-}"
  mkdir -p "$eco/$name/.devcontainer" "$eco/$name/.git"
  printf 'ARG EIGS_REF=v0.43.0\n' > "$eco/$name/.devcontainer/Dockerfile"
  if [ -n "$runcmd" ]; then
    mkdir -p "$eco/$name/.github/workflows"
    printf 'runCmd: %s\n' "$runcmd" > "$eco/$name/.github/workflows/ci.yml"
  fi
}

mk_consumer_block() {
  local eco="$1" name="$2"
  shift 2
  mkdir -p "$eco/$name/.devcontainer" "$eco/$name/.git" "$eco/$name/.github/workflows"
  printf 'ARG EIGS_REF=v0.43.0\n' > "$eco/$name/.devcontainer/Dockerfile"
  {
    printf 'runCmd: |\n'
    local line
    for line in "$@"; do
      printf '  %s\n' "$line"
    done
  } > "$eco/$name/.github/workflows/ci.yml"
}

mk_stub() {
  local path="$1" rc="$2"
  # --version is a separate probe and must succeed for a "runs, but the
  # consumer command fails" stub. A hanging/failing probe is mk_stub_hang_version
  # (plant E), not this helper -- sharing the run rc with --version was how
  # round 1 hid the unbounded probe.
  printf '%s\n' "#!/bin/sh" "if [ \"\${1:-}\" = --version ]; then echo 'eigenscript stub'; exit 0; fi" "exit $rc" > "$path"
  chmod +x "$path"
}

mk_stub_hang_version() {
  local path="$1"
  printf '%s\n' "#!/bin/sh" "if [ \"\${1:-}\" = --version ]; then sleep 30; echo hang-version; exit 0; fi" "exit 0" > "$path"
  chmod +x "$path"
}

plant_line() {
  local name="$1" st="$2" detail="${3:-}"
  if [ "$st" -eq 0 ]; then
    say "plant $name: FIRES${detail:+ -- $detail}"
  else
    say "plant $name: SILENT${detail:+ -- $detail}"
    ST_FAIL=1
  fi
}

exact_verdict() {
  local src="$1" v="$2" n
  n="$(printf '%s\n' "$src" | grep -c '^VERDICT:' || true)"
  [ "$n" = 1 ] && printf '%s\n' "$src" | grep -qx "VERDICT: $v"
}

exact_verdict_file() {
  local f="$1" v="$2" n
  [ -f "$f" ] || return 1
  n="$(grep -c '^VERDICT:' "$f" || true)"
  [ "$n" = 1 ] && grep -qx "VERDICT: $v" "$f"
}

# 0=FIRES 1=SILENT. LAST_PLANT_DETAIL for the SILENT line.
LAST_PLANT_DETAIL=""

plant_plan_gap() {
  local sh="$1" eco="$2"
  local out rc
  out="$("$sh" plan 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc"
  if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "GAP    zz-planted-consumer" \
     && printf '%s\n' "$out" | grep -q '^VERDICT: FAIL'; then
    return 0
  fi
  return 1
}

plant_honest_good() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc"
  if [ "$rc" -eq 0 ] \
     && exact_verdict_file "$rec" PASS \
     && exact_verdict "$out" PASS \
     && grep -q 'inventory=2 examined=2' "$rec" \
     && grep -q 'row|good_a|v0.43.0|PASS|' "$rec" \
     && grep -q 'row|good_b|v0.43.0|PASS|' "$rec" \
     && grep -q '^run_id=' "$rec" \
     && grep -q '^eco_root=' "$rec"; then
    return 0
  fi
  return 1
}

plant_early_stop() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_FAULT=stop_after=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep -E 'inventory=|VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  if [ "$rc" -eq 1 ] \
     && grep -q 'inventory=3 examined=1' "$rec" \
     && exact_verdict_file "$rec" FAIL \
     && exact_verdict "$out" FAIL; then
    return 0
  fi
  return 1
}

plant_empty_inventory() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'inventory=0 examined=0' "$rec" \
     && exact_verdict_file "$rec" FAIL \
     && exact_verdict "$out" FAIL; then
    return 0
  fi
  return 1
}

plant_missing_command() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|no_wf|v0.43.0|UNRUNNABLE|-|' "$rec" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

plant_skip_no_reason() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_FAULT=empty_skip_reason CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q '^skip|planted_empty_skip|' "$rec" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# Trailing-text plant: FIRES when a VERDICT: PASS substring exists but the
# line is not exactly VERDICT: PASS (the extra-mutant case).
plant_trailing_verdict() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc verdict=$(grep '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  if [ "$rc" -eq 0 ] \
     && grep -q 'VERDICT: PASS' "$rec" \
     && ! grep -qx 'VERDICT: PASS' "$rec"; then
    return 0
  fi
  if [ "$rc" -eq 0 ] \
     && printf '%s\n' "$out" | grep -q 'VERDICT: PASS' \
     && ! printf '%s\n' "$out" | grep -qx 'VERDICT: PASS'; then
    return 0
  fi
  return 1
}

apply_mutation() {
  local src="$1" dest="$2" kind="$3"
  python3 - "$src" "$dest" "$kind" << 'PY'
import sys
src, dest, kind = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src).read()
repls = {
    "examined-eq": (
        '  # CA-GUARD:examined-eq-inventory\n'
        '  elif [ "$EXAMINED" -ne "$INVENTORY" ]; then',
        '  # CA-GUARD:examined-eq-inventory\n'
        '  elif false && [ "$EXAMINED" -ne "$INVENTORY" ]; then',
    ),
    "nonempty": (
        '  # CA-GUARD:nonempty-inventory\n'
        '  if [ "$INVENTORY" -eq 0 ]; then',
        '  # CA-GUARD:nonempty-inventory\n'
        '  if false && [ "$INVENTORY" -eq 0 ]; then',
    ),
    "missing-command": (
        '  # CA-GUARD:missing-command\n'
        '  if [ -z "$cmd" ]; then\n'
        '    LAST_VERDICT=UNRUNNABLE',
        '  # CA-GUARD:missing-command\n'
        '  if [ -z "$cmd" ]; then\n'
        '    LAST_VERDICT=PASS',
    ),
    "skip-reason": (
        '  # CA-GUARD:skip-reason\n'
        '  if [ -z "$3" ]; then\n'
        '    SKIP_MISSING_REASON=1\n'
        '    ANY_BAD=1\n'
        '  fi',
        '  # CA-GUARD:skip-reason\n'
        '  if false && [ -z "$3" ]; then\n'
        '    SKIP_MISSING_REASON=1\n'
        '    ANY_BAD=1\n'
        '  fi',
    ),
    "exact-verdict": (
        "  # CA-GUARD:exact-verdict\n"
        "  printf 'VERDICT: %s\\n' \"$1\"",
        "  # CA-GUARD:exact-verdict\n"
        "  printf 'VERDICT: %s extra\\n' \"$1\"",
    ),
    "plan-gap": (
        '  # CA-GUARD:plan-gap\n'
        '  if [ "$GAPS" -gt 0 ]; then',
        '  # CA-GUARD:plan-gap\n'
        '  if false && [ "$GAPS" -gt 0 ]; then',
    ),
}
if kind not in repls:
    sys.stderr.write("unknown mutation %s\n" % kind)
    sys.exit(2)
a, b = repls[kind]
if a not in text:
    sys.stderr.write("mutation %s: needle not found\n" % kind)
    sys.exit(2)
text = text.replace(a, b, 1)
open(dest, "w").write(text)
sys.exit(0)
PY
}

prep_mutant() {
  local d="$1" kind="$2"
  mkdir -p "$d/tools"
  cp "$HERE/tools/consumer_acceptance.sh" "$d/tools/consumer_acceptance.sh.orig"
  cp "$HERE/tools/_extract_runcmd.py" "$d/tools/_extract_runcmd.py"
  if ! apply_mutation "$d/tools/consumer_acceptance.sh.orig" "$d/tools/consumer_acceptance.sh" "$kind"; then
    return 1
  fi
  chmod +x "$d/tools/consumer_acceptance.sh"
  if cmp -s "$d/tools/consumer_acceptance.sh.orig" "$d/tools/consumer_acceptance.sh"; then
    return 1
  fi
  return 0
}

selftest() {
  local st_root rec out rc pid
  ST_FAIL=0
  st_root="$(mktemp -d "${TMPDIR:-/tmp}/ca-st.XXXXXX")"
  trap 'if [ -n "${st_root:-}" ] && [ -d "${st_root:-}" ]; then find "$st_root" -type d -exec chmod u+w {} + 2>/dev/null || true; rm -rf "$st_root"; fi' EXIT

  local sh="$0"
  mk_stub "$st_root/stub-ok" 0
  mk_stub "$st_root/stub-bad" 1

  # --- plan plant: ungated consumer must FAIL the plan (GAP + VERDICT: FAIL + nonzero).
  local plan_eco="$st_root/plan-eco"
  mkdir -p "$plan_eco"
  mk_consumer "$plan_eco" zz-planted-consumer ""
  if CA_ECO="$plan_eco" plant_plan_gap "$sh" "$plan_eco"; then
    plant_line "plan-ungated" 0 "GAP named zz-planted-consumer, VERDICT: FAIL, nonzero"
  else
    plant_line "plan-ungated" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- control: two passing fake consumers, stub exits 0.
  local good_eco="$st_root/good-eco"
  mkdir -p "$good_eco"
  printf 'fixture\n' > "$good_eco/.ca_fixture"
  mk_consumer "$good_eco" good_a "eigenscript"
  mk_consumer "$good_eco" good_b '$EIGS'
  rec="$st_root/good.record"
  if plant_honest_good "$sh" "$good_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "control honest-good" 0 "VERDICT: PASS inventory=2 examined=2"
  else
    plant_line "control honest-good" 1 "$LAST_PLANT_DETAIL"
  fi

  # Plan on the same honest fixture must still PASS (plan mode unchanged).
  out="$(CA_ECO="$good_eco" "$sh" plan 2>&1)" || true
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
  out="$(CA_ECO="$skip_eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$st_root/stub-ok" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ] \
     && exact_verdict_file "$rec" PASS \
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
  rec="$st_root/a.record"
  out="$(CA_ECO="$a_eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$st_root/stub-bad" 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ] \
     && exact_verdict_file "$rec" FAIL \
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
  out="$(CA_ECO="$b_eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_DROP_BEFORE=victim CA_RECORD="$rec" "$sh" run "$st_root/stub-ok" 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ] \
     && exact_verdict_file "$rec" FAIL \
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
  mk_consumer "$c_eco" aaa_sleep "sleep 30"
  mk_consumer "$c_eco" zzz_pass "eigenscript"
  rec="$st_root/c.record"
  out="$(CA_ECO="$c_eco" CA_TIMEOUT=1 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$st_root/stub-ok" 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ] \
     && exact_verdict_file "$rec" FAIL \
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
  out="$(CA_ECO="$k_eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$st_root/stub-ok" 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ] \
     && exact_verdict_file "$rec" FAIL \
     && grep -q 'row|aaa_kill|v0.43.0|KILLED|137|' "$rec" \
     && grep -q 'row|zzz_ok|v0.43.0|PASS|' "$rec"; then
    plant_line "C2 killed" 0 "KILLED aaa_kill rc=137, zzz_ok still PASS"
  else
    plant_line "C2 killed" 1 "rc=$rc record=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  fi

  # --- D: SIGTERM mid-wave; record INCOMPLETE; exit 2; returns promptly.
  local d_eco="$st_root/d-eco"
  mkdir -p "$d_eco"
  printf 'fixture\n' > "$d_eco/.ca_fixture"
  mk_consumer "$d_eco" aaa_block "sleep 30"
  mk_consumer "$d_eco" zzz_after "eigenscript"
  rec="$st_root/d.record"
  CA_ECO="$d_eco" CA_TIMEOUT=20 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$st_root/stub-ok" >/dev/null 2>&1 &
  pid=$!
  local waited=0
  while [ "$waited" -lt 20 ]; do
    if [ -f "$rec" ] && grep -q 'status=INCOMPLETE' "$rec" 2>/dev/null; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  sleep 1
  local t0 t1 elapsed
  t0="$(date +%s)"
  kill -TERM "$pid" 2>/dev/null || true
  waited=0
  while [ "$waited" -lt 8 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid"
  rc=$?
  t1="$(date +%s)"
  elapsed=$((t1 - t0))
  if [ "$rc" -eq 2 ] \
     && grep -q 'VERDICT: INCOMPLETE' "$rec" \
     && grep -q 'status=INCOMPLETE' "$rec" \
     && [ "$elapsed" -le 5 ]; then
    plant_line "D interruption" 0 "record INCOMPLETE, exit 2, returned in ${elapsed}s"
  else
    plant_line "D interruption" 1 "rc=$rc elapsed=${elapsed}s record=$(tail -6 "$rec" 2>/dev/null | tr '\n' ' ')"
  fi

  # --- D2: SIGHUP is trapped the same way (exit 2, not 129).
  local dh_eco="$st_root/dh-eco"
  mkdir -p "$dh_eco"
  printf 'fixture\n' > "$dh_eco/.ca_fixture"
  mk_consumer "$dh_eco" aaa_block "sleep 30"
  mk_consumer "$dh_eco" zzz_after "eigenscript"
  rec="$st_root/dh.record"
  CA_ECO="$dh_eco" CA_TIMEOUT=20 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$st_root/stub-ok" >/dev/null 2>&1 &
  pid=$!
  waited=0
  while [ "$waited" -lt 20 ]; do
    if [ -f "$rec" ] && grep -q 'status=INCOMPLETE' "$rec" 2>/dev/null; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  sleep 1
  t0="$(date +%s)"
  kill -HUP "$pid" 2>/dev/null || true
  waited=0
  while [ "$waited" -lt 8 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid"
  rc=$?
  t1="$(date +%s)"
  elapsed=$((t1 - t0))
  if [ "$rc" -eq 2 ] \
     && grep -q 'VERDICT: INCOMPLETE' "$rec" \
     && [ "$elapsed" -le 5 ]; then
    plant_line "D2 sighup" 0 "SIGHUP -> INCOMPLETE, exit 2 (not 129), ${elapsed}s"
  else
    plant_line "D2 sighup" 1 "rc=$rc elapsed=${elapsed}s record=$(tail -6 "$rec" 2>/dev/null | tr '\n' ' ')"
  fi

  # --- E: hanging --version probe; stale PASS at the record path is gone.
  local e_eco="$st_root/e-eco"
  mkdir -p "$e_eco"
  printf 'fixture\n' > "$e_eco/.ca_fixture"
  mk_consumer "$e_eco" e_one "eigenscript"
  mk_stub_hang_version "$st_root/stub-hang-ver"
  rec="$st_root/e.record"
  printf '%s\n' '# stale' 'status=COMPLETE' 'inventory=1 examined=1' 'VERDICT: PASS' > "$rec"
  CA_ECO="$e_eco" CA_TIMEOUT=1 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$st_root/stub-hang-ver" >/dev/null 2>&1 &
  pid=$!
  waited=0
  while [ "$waited" -lt 8 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    plant_line "E hanging-probe" 1 "candidate --version still running after ${waited}s"
  else
    wait "$pid"
    rc=$?
    if [ "$rc" -ne 0 ] \
       && ! grep -qx 'VERDICT: PASS' "$rec" \
       && ! grep -q '^VERDICT: PASS$' "$rec" \
       && { grep -q '^run_id=' "$rec" || grep -q 'VERDICT: FAIL' "$rec" || grep -q 'VERDICT: INCOMPLETE' "$rec"; }; then
      plant_line "E hanging-probe" 0 "stale PASS superseded, verdict not PASS, exit=$rc"
    else
      plant_line "E hanging-probe" 1 "rc=$rc record=$(tail -8 "$rec" 2>/dev/null | tr '\n' ' ')"
    fi
  fi

  # --- F: unwritable record directory -- no VERDICT: PASS, exit 1.
  local f_eco="$st_root/f-eco" ro_dir rec_f
  mkdir -p "$f_eco"
  printf 'fixture\n' > "$f_eco/.ca_fixture"
  mk_consumer "$f_eco" f_one "eigenscript"
  ro_dir="$st_root/ro"
  mkdir -p "$ro_dir"
  rec_f="$ro_dir/record"
  chmod a-w "$ro_dir"
  out="$(CA_ECO="$f_eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec_f" "$sh" run "$st_root/stub-ok" 2>&1)"
  rc=$?
  chmod u+w "$ro_dir"
  if [ "$rc" -eq 1 ] \
     && ! printf '%s\n' "$out" | grep -q 'VERDICT: PASS' \
     && [ ! -e "$rec_f" ]; then
    plant_line "F unwritable-record" 0 "no VERDICT: PASS, exit 1, record absent"
  else
    plant_line "F unwritable-record" 1 "rc=$rc exists=$( [ -e "$rec_f" ] && echo yes || echo no ) out=$(printf '%s\n' "$out" | tail -3 | tr '\n' ' ')"
  fi

  # --- G: two-line block, first line fails, second would succeed -> FAIL row.
  local g_eco="$st_root/g-eco"
  mkdir -p "$g_eco"
  printf 'fixture\n' > "$g_eco/.ca_fixture"
  mk_consumer_block "$g_eco" blk_fail "false" "echo done"
  rec="$st_root/g.record"
  out="$(CA_ECO="$g_eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$st_root/stub-ok" 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|blk_fail|v0.43.0|FAIL|' "$rec" \
     && exact_verdict_file "$rec" FAIL; then
    plant_line "G block-set-e" 0 "false then echo done is a FAIL row"
  else
    plant_line "G block-set-e" 1 "rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  fi

  # --- early-stop: examined < inventory on a completed record (CA_FAULT).
  local es_eco="$st_root/es-eco"
  mkdir -p "$es_eco"
  printf 'fixture\n' > "$es_eco/.ca_fixture"
  mk_consumer "$es_eco" aaa "eigenscript"
  mk_consumer "$es_eco" bbb "eigenscript"
  mk_consumer "$es_eco" ccc "eigenscript"
  rec="$st_root/es.record"
  if plant_early_stop "$sh" "$es_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "early-stop" 0 "inventory=3 examined=1, VERDICT: FAIL"
  else
    plant_line "early-stop" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- empty inventory: only an EXCLUDED pinning repo.
  local z_eco="$st_root/z-eco"
  mkdir -p "$z_eco"
  printf 'fixture\n' > "$z_eco/.ca_fixture"
  mk_consumer "$z_eco" tmp "eigenscript"
  rec="$st_root/z.record"
  if plant_empty_inventory "$sh" "$z_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "empty-inventory" 0 "inventory=0 examined=0, VERDICT: FAIL"
  else
    plant_line "empty-inventory" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- missing command: pinning consumer, no workflow.
  local m_eco="$st_root/m-eco"
  mkdir -p "$m_eco"
  printf 'fixture\n' > "$m_eco/.ca_fixture"
  mk_consumer "$m_eco" no_wf ""
  rec="$st_root/m.record"
  if plant_missing_command "$sh" "$m_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "missing-command" 0 "row|no_wf|v0.43.0|UNRUNNABLE|-|, VERDICT: FAIL"
  else
    plant_line "missing-command" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- SKIP without a reason (CA_FAULT=empty_skip_reason).
  local sr_eco="$st_root/sr-eco"
  mkdir -p "$sr_eco"
  printf 'fixture\n' > "$sr_eco/.ca_fixture"
  mk_consumer "$sr_eco" keep "eigenscript"
  rec="$st_root/sr.record"
  if plant_skip_no_reason "$sh" "$sr_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "skip-no-reason" 0 "empty SKIP reason, VERDICT: FAIL"
  else
    plant_line "skip-no-reason" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- transversality: gut each guard, require its plant SILENT.
  say ""
  say "transverse: gut each guard, require its plant SILENT (and intact FIRES)"

  transverse_one() {
    local kind="$1" plant="$2" eco="$3" rec_prefix="$4"
    local md mutant rec_i rec_m
    md="$st_root/mutants/$kind"
    rec_i="$st_root/${rec_prefix}-intact.record"
    rec_m="$st_root/${rec_prefix}-mutant.record"
    rm -f "$rec_i" "$rec_m"
    local intact=SILENT mutant_st=BROKEN
    case "$plant" in
      early-stop)      plant_early_stop "$sh" "$eco" "$st_root/stub-ok" "$rec_i" && intact=FIRES || intact=SILENT ;;
      empty-inventory) plant_empty_inventory "$sh" "$eco" "$st_root/stub-ok" "$rec_i" && intact=FIRES || intact=SILENT ;;
      missing-command) plant_missing_command "$sh" "$eco" "$st_root/stub-ok" "$rec_i" && intact=FIRES || intact=SILENT ;;
      skip-no-reason)  plant_skip_no_reason "$sh" "$eco" "$st_root/stub-ok" "$rec_i" && intact=FIRES || intact=SILENT ;;
      plan-gap)        CA_ECO="$eco" plant_plan_gap "$sh" "$eco" && intact=FIRES || intact=SILENT ;;
      trailing-verdict) plant_trailing_verdict "$sh" "$eco" "$st_root/stub-ok" "$rec_i" && intact=FIRES || intact=SILENT ;;
    esac
    if ! prep_mutant "$md" "$kind"; then
      say "transverse $kind / $plant: intact=$intact mutant=BROKEN -- mutation did not land"
      ST_FAIL=1
      return
    fi
    mutant="$md/tools/consumer_acceptance.sh"
    # Sanity-start: the mutant must produce a VERDICT line on plan.
    local start_out
    start_out="$(CA_ECO="$good_eco" "$mutant" plan 2>&1)" || true
    if ! printf '%s' "$start_out" | grep -q '^VERDICT:'; then
      say "transverse $kind / $plant: intact=$intact mutant=BROKEN -- mutant plan emitted no VERDICT"
      ST_FAIL=1
      return
    fi
    case "$plant" in
      early-stop)      plant_early_stop "$mutant" "$eco" "$st_root/stub-ok" "$rec_m" && mutant_st=FIRES || mutant_st=SILENT ;;
      empty-inventory) plant_empty_inventory "$mutant" "$eco" "$st_root/stub-ok" "$rec_m" && mutant_st=FIRES || mutant_st=SILENT ;;
      missing-command) plant_missing_command "$mutant" "$eco" "$st_root/stub-ok" "$rec_m" && mutant_st=FIRES || mutant_st=SILENT ;;
      skip-no-reason)  plant_skip_no_reason "$mutant" "$eco" "$st_root/stub-ok" "$rec_m" && mutant_st=FIRES || mutant_st=SILENT ;;
      plan-gap)        CA_ECO="$eco" plant_plan_gap "$mutant" "$eco" && mutant_st=FIRES || mutant_st=SILENT ;;
      trailing-verdict) plant_trailing_verdict "$mutant" "$eco" "$st_root/stub-ok" "$rec_m" && mutant_st=FIRES || mutant_st=SILENT ;;
    esac
    # Trailing-text is inverted: the "guard" is the exact-line check, the
    # plant IS the extra-mutant. Intact production has no extra text so the
    # trailing-text plant is SILENT there; the extra-mutant must FIRE.
    if [ "$plant" = "trailing-verdict" ]; then
      if [ "$intact" = SILENT ] && [ "$mutant_st" = FIRES ]; then
        say "transverse $kind / $plant: intact=SILENT (no extra text) mutant=FIRES  OK"
      else
        say "transverse $kind / $plant: intact=$intact mutant=$mutant_st  FAIL (want intact SILENT, mutant FIRES)"
        ST_FAIL=1
      fi
      return
    fi
    if [ "$intact" = FIRES ] && [ "$mutant_st" = SILENT ]; then
      say "transverse $kind / $plant: intact=FIRES mutant=SILENT  OK"
    else
      say "transverse $kind / $plant: intact=$intact mutant=$mutant_st  FAIL (want intact FIRES, mutant SILENT)"
      ST_FAIL=1
    fi
  }

  transverse_one examined-eq     early-stop       "$es_eco"   t-es
  transverse_one nonempty        empty-inventory  "$z_eco"    t-z
  transverse_one missing-command missing-command  "$m_eco"    t-m
  transverse_one skip-reason     skip-no-reason   "$sr_eco"   t-sr
  transverse_one exact-verdict   trailing-verdict "$good_eco" t-tv
  transverse_one plan-gap        plan-gap         "$plan_eco" t-pg

  if [ "$ST_FAIL" -ne 0 ]; then
    say "SELF-TEST: FAIL -- one or more plants SILENT or a transverse row failed"
    exit 1
  fi
  say "SELF-TEST: PASS -- run-mode plants FIRE and each gutted guard silences its plant"
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
