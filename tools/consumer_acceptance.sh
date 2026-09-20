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
# Record lifecycle (the class, fail-closed):
#   At every moment from process start to exit, the file at CA_RECORD is
#   either THIS run's record in a truthful state, or absent -- never a
#   previous run's PASS. Every write that participates goes through
#   write_record, which returns nonzero on any failure and is checked
#   (write_record || die_record "why"). No || true on a record write.
#
#   First three actions of run_mode, before the inventory scan, before
#   the shim, before the candidate: install traps, invalidate the
#   previous record, write the INCOMPLETE header (inventory=PENDING
#   until the scan finishes -- that is truthful). Invalidating fails
#   closed: if the previous file cannot be moved aside, it is truncated
#   / overwritten in place so it is unreadable as PASS, then the run
#   FAILS immediately, exit 1. VERDICT: PASS is printed only after the
#   final record is written to a same-directory temp; RECORD_FINISHED=1
#   is set BEFORE that rename, so a signal after the rename is a
#   completed run. Exactly one VERDICT: line can ever exist in the
#   footer writer's output.
#
# Consumers run as a background job (setsid + timeout, wait in this shell)
# so a trap can kill the in-flight process group without waiting out the
# consumer budget. Block bodies run under bash -e -o pipefail -c.
# run_cleanup removes the run's scratch on every exit path.
#
# examined != inventory on a COMPLETED record is unreachable without a
# broken loop: the production path that stops early is an interrupt, and
# that writes INCOMPLETE (plant D). The completed-record clause is planted
# by CA_FAULT=stop_after=N under .ca_fixture (plant early-stop). The
# honest control also pins inventory=2 examined=2 by grep.
#
# CA-GUARD: comments name the checks the self-test guts in isolation.
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
  # Fixture-only pause so plant H can INT inside the scan window. The
  # production cost is one python fork per workflow; this sleep is the
  # deterministic stand-in under .ca_fixture, not a production delay.
  if [ -f "${ECO:-}/.ca_fixture" ] && [ -n "${CA_SCAN_PAUSE:-}" ]; then
    if [ -n "${CA_SCAN_READY:-}" ]; then
      printf 'ready\n' > "$CA_SCAN_READY"
    fi
    # Background + wait, not a foreground sleep: a trapped INT/TERM is
    # delivered during wait, matching run_bounded. A foreground sleep
    # swallows the signal until it exits and the trap never runs.
    sleep "$CA_SCAN_PAUSE" &
    wait $! || true
  fi
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
INVENTORY=0
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

# The single writer. Reads stdin. Returns 1 on any failure; sets
# RECORD_WRITE_ERR. mode is append | replace; optional tag names the
# temp file (footer uses "rewrite" so a PATH-shim can target the final
# rename). Callers check: write_record ... || die_record "why".
write_record() {
  local mode="${1:-}" tag="${2:-tmp}" dir tmp
  RECORD_WRITE_ERR=""
  if [ -z "${RECORD:-}" ]; then
    RECORD_WRITE_ERR="write_record: RECORD is unset"
    return 1
  fi
  case "$mode" in
    append)
      if [ ! -f "$RECORD" ]; then
        RECORD_WRITE_ERR="cannot append, $RECORD missing"
        return 1
      fi
      if ! cat >> "$RECORD"; then
        RECORD_WRITE_ERR="cannot append to $RECORD"
        return 1
      fi
      return 0
      ;;
    replace)
      dir="$(dirname "$RECORD")"
      tmp="$dir/.$(basename "$RECORD").${tag}.$$"
      if ! cat > "$tmp"; then
        RECORD_WRITE_ERR="cannot write record temp at $tmp"
        rm -f "$tmp"
        return 1
      fi
      if [ "$tag" = rewrite ]; then
        # CA-GUARD:finished-before-rename
        RECORD_FINISHED=1
      fi
      if ! mv "$tmp" "$RECORD"; then
        RECORD_WRITE_ERR="cannot rename record temp onto $RECORD"
        rm -f "$tmp"
        if [ "$tag" = rewrite ]; then
          RECORD_FINISHED=0
        fi
        return 1
      fi
      return 0
      ;;
    *)
      RECORD_WRITE_ERR="write_record: unknown mode ${mode:-empty}"
      return 1
      ;;
  esac
}

die_record() {
  local why="$1"
  say "consumer_acceptance: $why${RECORD_WRITE_ERR:+ ($RECORD_WRITE_ERR)}"
  if [ -n "${RECORD:-}" ] && [ -f "${RECORD:-}" ] && [ "${RECORD_FINISHED:-0}" -eq 0 ]; then
    write_record_footer FAIL COMPLETE || say "consumer_acceptance: also failed to write FAIL footer"
  fi
  verdict_line FAIL
  RECORD_FINISHED=1
  exit 1
}

# EXIT/INT/TERM/HUP: a record that never got a footer is INCOMPLETE. Guard
# every expansion -- under set -u a trap abort skips the rest of cleanup.
# Foreign (previous-run) files are clobbered, never appended-to, so a PASS
# from another run cannot survive this run's trap. This run's own file
# already carries VERDICT: INCOMPLETE from the header; we only append when
# the footer has already written PASS/FAIL and RECORD_FINISHED is still 0
# (the finalization race the finished-before-rename guard exists to close).
finish_incomplete() {
  [ "${RECORD_FINISHED:-0}" -eq 1 ] && return
  [ -n "${RECORD:-}" ] && [ -f "$RECORD" ] || return
  if grep -q "^run_id=${RUN_ID}$" "$RECORD" 2>/dev/null; then
    if grep -q '^VERDICT: INCOMPLETE$' "$RECORD" \
       && ! grep -q '^VERDICT: PASS$' "$RECORD" \
       && ! grep -q '^VERDICT: FAIL$' "$RECORD"; then
      RECORD_FINISHED=1
      return
    fi
    write_record append <<EOF || say "consumer_acceptance: failed to write INCOMPLETE footer"
status=INCOMPLETE
examined=${EXAMINED:-0}
inventory=${INVENTORY:-0} examined=${EXAMINED:-0}
VERDICT: INCOMPLETE
EOF
  else
    clobber_record_in_place || say "consumer_acceptance: failed to clobber stale record at $RECORD"
  fi
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
    # CA-GUARD:scratch-cleanup
    rm -rf "$WORK"
    WORK=""
  fi
}

install_run_traps() {
  # Snapshot RECORD_FINISHED before cleanup: finish_incomplete sets the
  # flag after writing INCOMPLETE, which is not a completed run.
  trap 'fin=${RECORD_FINISHED:-0}; run_cleanup; if [ "$fin" -eq 1 ]; then exit "${RUN_RC:-0}"; else exit 2; fi' INT TERM HUP
  trap 'run_cleanup' EXIT
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
  mv "$RECORD" "$aside"
}

# Truncate/overwrite in place. The file itself is writable even when the
# directory is not; this is how a stale PASS is destroyed before we FAIL.
clobber_record_in_place() {
  if ! : > "$RECORD"; then
    RECORD_WRITE_ERR="cannot truncate $RECORD in place"
    return 1
  fi
  write_record append <<EOF
# consumer_acceptance record
run_id=${RUN_ID:-unknown}
started=${STARTED:-}
eco_root=${ECO:-}
status=INCOMPLETE
note=clobbered in place; directory would not allow stash
VERDICT: INCOMPLETE
EOF
}

# Fail closed: move aside, or destroy PASS in place and still return 1.
invalidate_previous_record() {
  [ -e "$RECORD" ] || return 0
  if stash_previous_record; then
    return 0
  fi
  clobber_record_in_place
  RECORD_WRITE_ERR="${RECORD_WRITE_ERR:-cannot move aside $RECORD}"
  return 1
}

write_record_header() {
  write_record replace tmp <<EOF
# consumer_acceptance record
run_id=$RUN_ID
started=$STARTED
eco_root=${ECO:-PENDING}
block_shell=bash -e -o pipefail -c
candidate_path=${CAND_ABS:-PENDING}
candidate_version=PENDING
eigenscript_resolved=${RESOLVED:-PENDING}
inventory=PENDING
examined=PENDING
status=INCOMPLETE
# row|name|pin|verdict|rc|duration_s
VERDICT: INCOMPLETE
EOF
}

write_record_footer() {
  local verdict="$1" status="$2" line content n
  if [ ! -f "$RECORD" ]; then
    RECORD_WRITE_ERR="footer: $RECORD missing"
    return 1
  fi
  content="$(
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        inventory=PENDING)         printf 'inventory=%s\n' "${INVENTORY:-0}" ;;
        examined=PENDING)          printf 'examined=%s\n' "${EXAMINED:-0}" ;;
        status=INCOMPLETE|status=RUNNING) printf 'status=%s\n' "$status" ;;
        candidate_path=PENDING)    printf 'candidate_path=%s\n' "${CAND_ABS:-}" ;;
        candidate_version=PENDING) printf 'candidate_version=%s\n' "${CAND_VER:-}" ;;
        eigenscript_resolved=PENDING) printf 'eigenscript_resolved=%s\n' "${RESOLVED:-}" ;;
        "VERDICT: INCOMPLETE")     verdict_line "$verdict" ;;
        VERDICT:*)                 ;; # drop any other verdict; we emit one
        *)                         printf '%s\n' "$line" ;;
      esac
    done < "$RECORD"
    printf 'probe_rc=%s\n' "${PROBE_RC:--}"
    printf 'inventory=%s examined=%s\n' "${INVENTORY:-0}" "${EXAMINED:-0}"
    printf 'status=%s\n' "$status"
  )"
  n="$(printf '%s\n' "$content" | grep -c '^VERDICT:' || true)"
  if [ "$n" != 1 ]; then
    RECORD_WRITE_ERR="footer would write $n VERDICT lines (want 1)"
    return 1
  fi
  write_record replace rewrite <<<"$content"
}

append_row() {
  write_record append <<<"row|$1|$2|$3|$4|$5" || die_record "cannot append row to $RECORD"
}

append_skip() {
  # CA-GUARD:skip-reason
  if [ -z "$3" ]; then
    SKIP_MISSING_REASON=1
    ANY_BAD=1
  fi
  write_record append <<<"skip|$1|$2|$3" || die_record "cannot append skip to $RECORD"
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
  # CA-GUARD:block-pipefail
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
    die_record "failed to write final record"
  fi
  say "inventory=$INVENTORY examined=$EXAMINED"
  verdict_line "$final"
  RECORD_FINISHED=1
  exit "$RUN_RC"
}

run_mode() {
  # CA-GUARD:not-crash
  local cand="${1:-}"
  resolve_eco
  probe_timeout
  # Unset → default 1800. Empty / 0 / 00 / non-integer → exit 2 below.
  if [ "${CA_TIMEOUT+set}" = set ]; then
    BUDGET="$CA_TIMEOUT"
  else
    BUDGET=1800
  fi
  KILL_AFTER="${CA_KILL_AFTER:-10}"

  RUN_ID="$(date +%s).$$.${RANDOM:-0}"
  STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)"

  if [ -n "${CA_RECORD:-}" ]; then
    RECORD="$CA_RECORD"
  else
    RECORD="$(mktemp "${TMPDIR:-/tmp}/ca-record.XXXXXX")"
  fi

  # First three actions -- before the inventory scan, before the shim,
  # before the candidate. A previous PASS must not outlive this point.
  # CA-GUARD:traps-before-scan
  install_run_traps
  # CA-GUARD:invalidate-fail-closed
  invalidate_previous_record || die_record "cannot invalidate previous record at $RECORD"
  write_record_header || die_record "cannot initialise record at $RECORD"
  # CA-GUARD:end-traps-before-scan

  # CA-GUARD:timeout-positive
  case "$BUDGET" in
    ''|*[!0-9]*)
      say "consumer_acceptance: CA_TIMEOUT must be a positive integer (got ${CA_TIMEOUT:-})"
      exit 2
      ;;
  esac
  if [ "$((10#$BUDGET))" -lt 1 ]; then
    say "consumer_acceptance: CA_TIMEOUT must be a positive integer (got ${CA_TIMEOUT:-})"
    exit 2
  fi
  # CA-GUARD:end-timeout-positive

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

  WORK="$(mktemp -d "${TMPDIR:-/tmp}/ca-run.XXXXXX")"
  SHIM="$WORK/bin"
  mkdir -p "$SHIM"
  ln -s "$CAND_ABS" "$SHIM/eigenscript"
  RESOLVED="$SHIM/eigenscript"

  # CA-GUARD:scan-inventory
  scan_inventory
  # CA-GUARD:end-scan-inventory

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

# Extra workflow files without runCmd so accept_cmd_of forks python more
# than once per consumer -- plant H needs the scan to outlast a 0.5s INT.
mk_consumer_padded() {
  mk_consumer "$1" "$2" "$3"
  mkdir -p "$1/$2/.github/workflows"
  printf '# no runCmd\n' > "$1/$2/.github/workflows/00-a.yml"
  printf '# no runCmd\n' > "$1/$2/.github/workflows/00-b.yml"
  printf '# no runCmd\n' > "$1/$2/.github/workflows/00-c.yml"
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
# LAST_PLANT_OUT/REC/RC feed mutant_not_fires_kind: a mutant that did not
# FIRE is SILENT only if it printed exactly VERDICT: PASS (the fault
# genuinely read as success). Anything else is BROKEN-MUTANT.
LAST_PLANT_DETAIL=""
LAST_PLANT_OUT=""
LAST_PLANT_REC=""
LAST_PLANT_RC=""

note_plant() {
  LAST_PLANT_OUT="${1:-}"
  LAST_PLANT_REC="${2:-}"
  LAST_PLANT_RC="${3:-}"
}

mutant_not_fires_kind() {
  local rec="${LAST_PLANT_REC:-}" out="${LAST_PLANT_OUT:-}"
  # "exactly VERDICT: PASS" means the fault read as success: a PASS
  # verdict line (run mode) or "VERDICT: PASS -- ..." (plan mode).
  # A mutant that emitted no PASS is BROKEN-MUTANT, not a catch.
  if [ -n "$rec" ] && [ -f "$rec" ] && grep -q '^VERDICT: PASS' "$rec"; then
    printf '%s' SILENT
    return
  fi
  if printf '%s\n' "$out" | grep -q '^VERDICT: PASS'; then
    printf '%s' SILENT
    return
  fi
  printf '%s' BROKEN-MUTANT
}

plant_plan_gap() {
  local sh="$1" eco="$2"
  local out rc
  out="$("$sh" plan 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc"
  note_plant "$out" "" "$rc"
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
  note_plant "$out" "$rec" "$rc"
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
  note_plant "$out" "$rec" "$rc"
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
  note_plant "$out" "$rec" "$rc"
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
  note_plant "$out" "$rec" "$rc"
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
  note_plant "$out" "$rec" "$rc"
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
  note_plant "$out" "$rec" "$rc"
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

# H: INT in the pre-scan window over a stale PASS. FIRE: record is not
# PASS, exit 2. The 16-consumer skeleton makes scan_inventory take ~1s+
# (one python fork per workflow file) so 0.5s lands inside the scan.
#
# bash `&` sets SIGINT to SIG_IGN in the child, and a signal ignored on
# entry cannot be trapped (POSIX). Spawn via python so SIGINT is SIG_DFL
# and install_run_traps' INT trap actually fires.
plant_prescan_int() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local pid waited rc mark leftover
  mark="$(mktemp "${TMPDIR:-/tmp}/ca-hmark.XXXXXX")"
  local ready="${rec}.ready"
  rm -f "$ready"
  printf '%s\n' '# stale' 'run_id=OLD_RUN' 'status=COMPLETE' 'inventory=1 examined=1' 'VERDICT: PASS' > "$rec"
  CA_ECO="$eco" CA_TIMEOUT=20 CA_KILL_AFTER=1 CA_RECORD="$rec" CA_SCAN_PAUSE=2 CA_SCAN_READY="$ready" \
    python3 -c 'import os,signal,sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp("bash", ["bash"] + sys.argv[1:])' "$sh" run "$stub" >/dev/null 2>&1 &
  pid=$!
  waited=0
  while [ ! -f "$ready" ] && [ "$waited" -lt 40 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if [ ! -f "$ready" ]; then
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -f "$mark"
    note_plant "" "$rec" 98
    LAST_PLANT_DETAIL="scan never reached pause (ready missing)"
    return 1
  fi
  sleep 0.2
  kill -INT "$pid" 2>/dev/null
  waited=0
  while [ "$waited" -lt 8 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rc=99
  else
    wait "$pid"
    rc=$?
  fi
  leftover="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'ca-run.*' -newer "$mark" 2>/dev/null || true)"
  rm -f "$mark"
  if [ -n "$leftover" ]; then
    # Mutant without traps leaks scratch; do not leave it.
    # shellcheck disable=SC2086
    rm -rf $leftover
  fi
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "" "$rec" "$rc"
  if [ "$rc" -eq 2 ] && { [ ! -f "$rec" ] || ! grep -q '^VERDICT: PASS$' "$rec"; }; then
    return 0
  fi
  return 1
}

# I: stale PASS + unwritable directory. FIRE: record not readable as PASS, exit 1.
# The passed rec path is a unique prefix; the plant owns a sibling directory
# so chmod a-w cannot land on the self-test root (or any shared dir).
plant_stale_unwritable() {
  local sh="$1" eco="$2" stub="$3" rec_hint="$4"
  local dir rec out rc
  dir="${rec_hint}.rodir"
  mkdir -p "$dir"
  rec="$dir/record"
  printf '%s\n' 'run_id=OLD_RUN' 'status=COMPLETE' 'inventory=1 examined=1' 'VERDICT: PASS' > "$rec"
  chmod a-w "$dir"
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  chmod u+w "$dir"
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] && { [ ! -f "$rec" ] || ! grep -q '^VERDICT: PASS$' "$rec"; }; then
    return 0
  fi
  return 1
}

# J: signal during finalization (PATH shim for mv). FIRE: exactly one VERDICT line.
plant_footer_signal() {
  local sh="$1" eco="$2" stub="$3" rec="$4" shim="${5:-}"
  local out rc n env_path
  env_path="$PATH"
  [ -n "$shim" ] && env_path="$shim:$PATH"
  out="$(PATH="$env_path" CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  n=0
  [ -f "$rec" ] && n="$(grep -c '^VERDICT:' "$rec" || true)"
  LAST_PLANT_DETAIL="rc=$rc n=$n rec=$(grep '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$n" = 1 ]; then
    return 0
  fi
  return 1
}

# K: CA_TIMEOUT=0 / 00 must exit 2.
plant_timeout_zero() {
  local sh="$1" eco="$2" stub="$3" rec="$4" val="$5"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT="$val" CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="val=$val rc=$rc"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q 'positive integer'; then
    return 0
  fi
  return 1
}

# L: false | true is a FAIL row (pipefail).
plant_pipefail() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|pipe_fail|v0.43.0|FAIL|' "$rec" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# M: after a run, no /tmp/ca-run.* newer than the run's start remains.
plant_scratch_cleanup() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local mark leftover out rc
  mark="$(mktemp "${TMPDIR:-/tmp}/ca-mark.XXXXXX")"
  sleep 0.05
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  leftover="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'ca-run.*' -newer "$mark" 2>/dev/null || true)"
  rm -f "$mark"
  LAST_PLANT_DETAIL="rc=$rc leftover=$(printf '%s' "$leftover" | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ -z "$leftover" ]; then
    return 0
  fi
  # Mutant leftover must not escape the self-test.
  if [ -n "$leftover" ]; then
    # shellcheck disable=SC2086
    rm -rf $leftover
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
    "invalidate-fail-closed": (
        '  # CA-GUARD:invalidate-fail-closed\n'
        '  invalidate_previous_record || die_record "cannot invalidate previous record at $RECORD"',
        '  # CA-GUARD:invalidate-fail-closed\n'
        '  true',
    ),
    "no-pipefail": (
        '  # CA-GUARD:block-pipefail\n'
        '  run_bounded "$log" bash -e -o pipefail -c "$cd_cmd"',
        '  # CA-GUARD:block-pipefail\n'
        '  run_bounded "$log" bash -e -c "$cd_cmd"',
    ),
    "no-cleanup": (
        '    # CA-GUARD:scratch-cleanup\n'
        '    rm -rf "$WORK"',
        '    # CA-GUARD:scratch-cleanup\n'
        '    :',
    ),
    "crash-early": (
        '  # CA-GUARD:not-crash\n'
        '  local cand="${1:-}"',
        '  # CA-GUARD:not-crash\n'
        '  exit 7\n'
        '  local cand="${1:-}"',
    ),
}
if kind == "traps-after-scan":
    start = "  # CA-GUARD:traps-before-scan\n"
    end = "  # CA-GUARD:end-traps-before-scan\n"
    scan_end = "  # CA-GUARD:end-scan-inventory\n"
    i = text.find(start)
    j = text.find(end)
    if i < 0 or j < 0 or j < i:
        sys.stderr.write("mutation traps-after-scan: block not found\n")
        sys.exit(2)
    j += len(end)
    block = text[i:j]
    text = text[:i] + text[j:]
    k = text.find(scan_end)
    if k < 0:
        sys.stderr.write("mutation traps-after-scan: scan end not found\n")
        sys.exit(2)
    k += len(scan_end)
    text = text[:k] + block + text[k:]
elif kind == "timeout-zero":
    start = "  # CA-GUARD:timeout-positive\n"
    end = "  # CA-GUARD:end-timeout-positive\n"
    i = text.find(start)
    j = text.find(end)
    if i < 0 or j < 0 or j < i:
        sys.stderr.write("mutation timeout-zero: block not found\n")
        sys.exit(2)
    j += len(end)
    text = text[:i] + start + "  : # gutted timeout validation\n" + end + text[j:]
elif kind == "finished-after-rename":
    # Move RECORD_FINISHED=1 from before mv to after successful mv.
    a = (
        '        # CA-GUARD:finished-before-rename\n'
        '        RECORD_FINISHED=1\n'
    )
    b = (
        '        # CA-GUARD:finished-before-rename\n'
        '        :\n'
    )
    if a not in text:
        sys.stderr.write("mutation finished-after-rename: before-flag not found\n")
        sys.exit(2)
    text = text.replace(a, b, 1)
    needle = (
        '      if ! mv "$tmp" "$RECORD"; then\n'
        '        RECORD_WRITE_ERR="cannot rename record temp onto $RECORD"\n'
        '        rm -f "$tmp"\n'
        '        if [ "$tag" = rewrite ]; then\n'
        '          RECORD_FINISHED=0\n'
        '        fi\n'
        '        return 1\n'
        '      fi\n'
        '      return 0\n'
    )
    repl = (
        '      if ! mv "$tmp" "$RECORD"; then\n'
        '        RECORD_WRITE_ERR="cannot rename record temp onto $RECORD"\n'
        '        rm -f "$tmp"\n'
        '        if [ "$tag" = rewrite ]; then\n'
        '          RECORD_FINISHED=0\n'
        '        fi\n'
        '        return 1\n'
        '      fi\n'
        '      if [ "$tag" = rewrite ]; then\n'
        '        RECORD_FINISHED=1\n'
        '      fi\n'
        '      return 0\n'
    )
    if needle not in text:
        sys.stderr.write("mutation finished-after-rename: mv block not found\n")
        sys.exit(2)
    text = text.replace(needle, repl, 1)
elif kind in repls:
    a, b = repls[kind]
    if a not in text:
        sys.stderr.write("mutation %s: needle not found\n" % kind)
        sys.exit(2)
    text = text.replace(a, b, 1)
else:
    sys.stderr.write("unknown mutation %s\n" % kind)
    sys.exit(2)
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

  # --- H: INT in the pre-scan window over a stale PASS (16-consumer skeleton).
  local h_eco="$st_root/h-eco" hi
  mkdir -p "$h_eco"
  printf 'fixture\n' > "$h_eco/.ca_fixture"
  hi=1
  while [ "$hi" -le 16 ]; do
    mk_consumer_padded "$h_eco" "c$(printf '%02d' "$hi")" "eigenscript"
    hi=$((hi + 1))
  done
  rec="$st_root/h.record"
  if plant_prescan_int "$sh" "$h_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "H prescan-int" 0 "stale PASS gone, exit 2"
  else
    plant_line "H prescan-int" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- I: stale PASS + unwritable directory.
  local i_eco="$st_root/i-eco" i_dir
  mkdir -p "$i_eco" "$st_root/i-ro"
  printf 'fixture\n' > "$i_eco/.ca_fixture"
  mk_consumer "$i_eco" i_one "eigenscript"
  rec="$st_root/i-ro/record"
  if plant_stale_unwritable "$sh" "$i_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "I stale-unwritable" 0 "record not PASS, exit 1"
  else
    plant_line "I stale-unwritable" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- J: signal during finalization -- exactly one VERDICT line.
  local j_eco="$st_root/j-eco" j_shim="$st_root/j-shim"
  mkdir -p "$j_eco" "$j_shim"
  printf 'fixture\n' > "$j_eco/.ca_fixture"
  mk_consumer "$j_eco" j_one "eigenscript"
  printf '%s\n' '#!/bin/bash' '/usr/bin/mv "$@" || exit $?' 'case "$1" in *.rewrite.*) kill -HUP "$PPID" ;; esac' 'exit 0' > "$j_shim/mv"
  chmod +x "$j_shim/mv"
  rec="$st_root/j.record"
  if plant_footer_signal "$sh" "$j_eco" "$st_root/stub-ok" "$rec" "$j_shim"; then
    plant_line "J footer-signal" 0 "exactly one VERDICT line"
  else
    plant_line "J footer-signal" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- K: CA_TIMEOUT=0 and 00 both exit 2.
  # Not k_eco: C2 already bound that name to the kill fixture.
  local tz_eco="$st_root/tz-eco"
  mkdir -p "$tz_eco"
  printf 'fixture\n' > "$tz_eco/.ca_fixture"
  mk_consumer "$tz_eco" tz_one "eigenscript"
  rec="$st_root/k0.record"
  if plant_timeout_zero "$sh" "$tz_eco" "$st_root/stub-ok" "$rec" 0 \
     && plant_timeout_zero "$sh" "$tz_eco" "$st_root/stub-ok" "$st_root/k00.record" 00 \
     && plant_timeout_zero "$sh" "$tz_eco" "$st_root/stub-ok" "$st_root/kempty.record" ""; then
    plant_line "K timeout-zero" 0 "0, 00 and empty all exit 2"
  else
    plant_line "K timeout-zero" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- L: false | true is a FAIL row (pipefail).
  local l_eco="$st_root/l-eco"
  mkdir -p "$l_eco"
  printf 'fixture\n' > "$l_eco/.ca_fixture"
  mk_consumer_block "$l_eco" pipe_fail "false | true"
  rec="$st_root/l.record"
  if plant_pipefail "$sh" "$l_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "L pipefail" 0 "false | true is a FAIL row"
  else
    plant_line "L pipefail" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- M: scratch dirs do not outlive the run.
  rec="$st_root/m-scratch.record"
  if plant_scratch_cleanup "$sh" "$good_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "M scratch-cleanup" 0 "no ca-run leftover"
  else
    plant_line "M scratch-cleanup" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- plant-of-plant: a mutant that exits 7 is BROKEN-MUTANT, not SILENT.
  local cr_md="$st_root/mutants/crash-early" cr_mutant cr_rec
  cr_rec="$st_root/crash.record"
  if ! prep_mutant "$cr_md" crash-early; then
    plant_line "broken-mutant-class" 1 "crash-early mutation did not land"
  else
    cr_mutant="$cr_md/tools/consumer_acceptance.sh"
    plant_early_stop "$cr_mutant" "$es_eco" "$st_root/stub-ok" "$cr_rec" || true
    if [ "$(mutant_not_fires_kind)" = BROKEN-MUTANT ]; then
      plant_line "broken-mutant-class" 0 "exit-7 mutant is BROKEN-MUTANT, not SILENT"
    else
      plant_line "broken-mutant-class" 1 "exit-7 mutant classified as $(mutant_not_fires_kind)"
    fi
  fi

  # --- transversality: gut each guard, require its plant SILENT.
  say ""
  say "transverse: gut each guard, require its plant SILENT (and intact FIRES)"

  run_named_plant() {
    local fn="$1" script="$2" eco="$3" rec="$4" extra="${5:-}"
    case "$fn" in
      early-stop)       plant_early_stop "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      empty-inventory)  plant_empty_inventory "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      missing-command)  plant_missing_command "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      skip-no-reason)   plant_skip_no_reason "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      plan-gap)         CA_ECO="$eco" plant_plan_gap "$script" "$eco" ;;
      trailing-verdict) plant_trailing_verdict "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      prescan-int)      plant_prescan_int "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      stale-unwritable) plant_stale_unwritable "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      footer-signal)    plant_footer_signal "$script" "$eco" "$st_root/stub-ok" "$rec" "$extra" ;;
      timeout-zero)     plant_timeout_zero "$script" "$eco" "$st_root/stub-ok" "$rec" 00 ;;
      pipefail)         plant_pipefail "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      scratch-cleanup)  plant_scratch_cleanup "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      *)                return 2 ;;
    esac
  }

  transverse_one() {
    local kind="$1" plant="$2" eco="$3" rec_prefix="$4"
    local extra="${5:-}"
    local md mutant rec_i rec_m
    md="$st_root/mutants/$kind"
    rec_i="$st_root/${rec_prefix}-intact.record"
    rec_m="$st_root/${rec_prefix}-mutant.record"
    rm -f "$rec_i" "$rec_m"
    local intact=SILENT mutant_st=BROKEN
    if run_named_plant "$plant" "$sh" "$eco" "$rec_i" "$extra"; then
      intact=FIRES
    else
      intact=SILENT
    fi
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
    if run_named_plant "$plant" "$mutant" "$eco" "$rec_m" "$extra"; then
      mutant_st=FIRES
    else
      mutant_st="$(mutant_not_fires_kind)"
    fi
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
    if [ "$mutant_st" = BROKEN-MUTANT ]; then
      say "transverse $kind / $plant: intact=$intact mutant=BROKEN-MUTANT  FAIL (mutant did not print VERDICT: PASS; rc=${LAST_PLANT_RC:-} rec=${LAST_PLANT_REC:-} recV=$(grep '^VERDICT:' "${LAST_PLANT_REC:-/dev/null}" 2>/dev/null | tr '\n' '|') detail=${LAST_PLANT_DETAIL:-} out=$(printf '%s\n' "${LAST_PLANT_OUT:-}" | tail -8 | tr '\n' '|'))"
      ST_FAIL=1
      return
    fi
    if [ "$intact" = FIRES ] && [ "$mutant_st" = SILENT ]; then
      say "transverse $kind / $plant: intact=FIRES mutant=SILENT  OK"
    else
      say "transverse $kind / $plant: intact=$intact mutant=$mutant_st  FAIL (want intact FIRES, mutant SILENT)"
      ST_FAIL=1
    fi
  }

  transverse_one examined-eq             early-stop       "$es_eco"   t-es
  transverse_one nonempty                empty-inventory  "$z_eco"    t-z
  transverse_one missing-command         missing-command  "$m_eco"    t-m
  transverse_one skip-reason             skip-no-reason   "$sr_eco"   t-sr
  transverse_one exact-verdict           trailing-verdict "$good_eco" t-tv
  transverse_one plan-gap                plan-gap         "$plan_eco" t-pg
  transverse_one traps-after-scan        prescan-int      "$h_eco"    t-h
  transverse_one invalidate-fail-closed  stale-unwritable "$i_eco"    t-i
  transverse_one finished-after-rename   footer-signal    "$j_eco"    t-j "$j_shim"
  transverse_one timeout-zero            timeout-zero     "$tz_eco"   t-k
  transverse_one no-pipefail             pipefail         "$l_eco"    t-l
  transverse_one no-cleanup              scratch-cleanup  "$good_eco" t-sc

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
