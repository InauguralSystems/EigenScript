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
# cannot be found, whose command is SKIPPED, or whose command never reaches
# the candidate must fail the run. A release gate that can quietly examine
# fewer consumers than last time is the failure mode this whole file exists
# to prevent (mechanical-gates 15, 165, 113, 170).
#
#   tools/consumer_acceptance.sh plan            what would run, and coverage
#   tools/consumer_acceptance.sh run <tree-or-binary> [--full <binary>] [--gfx <binary>]
#     Candidate SET: eigenscript is always shimmed from the first argument.
#     --full shims eigenscript-full; --gfx shims eigenscript-gfx. A name a
#     consumer invokes that the set does not cover is UNRUNNABLE|prereq:variant:<name>
#     and a 127-shim of that name sits on PATH (never a stale PATH fall-through).
#     The name set is DERIVED, never typed: every text file in the checkout
#     (grep -rIl, minus .git -- no extension allowlist, so a .py, a Makefile
#     or an extensionless script counts) is scanned for eigenscript and
#     eigenscript-[a-z0-9-]+ (multi-hyphen included). The check runs in
#     run_one too, not only on the runCmd tokens, so a name reached from a
#     script the consumer CALLS is refused before the stale binary is.
#     PATH shim logs argv+rc to a scratch file under a directory the consumer
#     is never told about (not the shim dir, not $EIGS_DIR, not their parents);
#     the path is baked into the shim (not exported; not named CA_*). cand_calls
#     counts NON-TRIVIAL invocations (a .eigs path or a non-flag positional).
#     --version/--api/--help/bare are `probe` and do not count. cand_calls=0
#     cannot be PASS (UNEXERCISED). Command rc 0 with cand_ok=0 cand_fail>0 is
#     SWALLOWED. EIGS_DIR is a COPY overlay (src/, lib/, top-level files; never
#     .git; src/eigenscript is the shim; dirs copied with cp -rL; a partial
#     copy's per-entry retry rm -rf's the destination first).
#     EIGENSCRIPT_BIN points at the shim; EIGENSCRIPT_GFX is exported only
#     when CAND_HAS_GFX=1 or --gfx was given. consumer_skips counts ^SKIP lines
#     in the consumer's combined output; a PASS with skips is PASS|skips=N, not
#     a bare PASS. Every non-PASS row is followed by log|<name>|<line> (last 60
#     lines of combined output). CA_LOGS=<dir> copies those logs before cleanup.
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
#   CA_DROP_BEFORE  self-test only: BEFORE the inventory scan, remove this
#                   consumer's checkout so the declared-set floor fires.
#                   Honoured ONLY if $CA_ECO/.ca_fixture exists, so it cannot
#                   reach a real sibling.
#   CA_FAULT    self-test only, same .ca_fixture gate:
#                 stop_after=N       break the wave after N examined rows
#                                    (the completed-record path for
#                                    examined < inventory; interrupt is plant D)
#                 empty_skip_reason  append a SKIP row with an empty reason
#                 foreign_record     replace the record with a different
#                                    run_id before the first row (plant O)
#                 fail_footer        make the final footer write fail after
#                                    planting a FAIL body (plant P)
#                 pause_before_rename sleep after writing the footer temp and
#                                    before mv (plant J2); INT/TERM/HUP then
#                                    is INCOMPLETE
#                 show_tmp           print record_tmp_dir=<dir> of the replace
#                                    temp (must equal the record's directory)
#                 overlay_partial    force the first cp -rL of src/ to fail
#                                    after creating dst/src/data, so the
#                                    per-entry retry runs (plant overlay-partial)
#                 record_floor=N     fixture-gated record floor of N (plant B3)
#                 pretend_root       self-test: take the uid-0 decision branch
#                                    of plant stale-unwritable (on a non-root
#                                    box no drop tool applies, so the plant
#                                    SKIPs by name and is counted)
#
# Record lifecycle (the class, fail-closed):
#   At every moment from process start to exit, the file at CA_RECORD is
#   either THIS run's record in a truthful state, or absent -- never a
#   previous run's PASS, never a foreign PASS. Every write that
#   participates goes through write_record, which returns nonzero on any
#   failure and is checked (write_record || die_record "why"). No || true
#   on a record write. write_record append refuses unless the file's
#   header carries run_id=$RUN_ID (empty files, used by in-place clobber,
#   are the one exception).
#
#   Exclusive ownership: a mkdir lock on <record>.lock.d is taken BEFORE
#   invalidating the previous record and held through cleanup. A second
#   invocation on the same CA_RECORD refuses immediately (exit 2, touches
#   nothing). A stale lock (holder pid dead) is reclaimed with a note in
#   the header.
#
#   First actions of run_mode, before the inventory scan, before the
#   shim, before the candidate: install traps, take the record lock,
#   create the scratch dir, invalidate the previous record, write the
#   INCOMPLETE header (inventory=PENDING until the scan finishes -- that
#   is truthful). Invalidating fails closed: if the previous file cannot
#   be moved aside, it is truncated / overwritten in place so it is
#   unreadable as PASS, then the run FAILS immediately, exit 1.
#   VERDICT: PASS is printed only after the final record is written to a
#   temp next to the record (same directory, then mv). RECORD_FINISHED=1
#   is set only after that rename returns 0. The INT/TERM/HUP/EXIT trap
#   re-reads the record's VERDICT: line (and status=COMPLETE) rather than
#   trusting the variable, so HUP-after-rename is still a completed run
#   and a signal between footer-write and rename is INCOMPLETE. Exactly
#   one VERDICT: line can ever exist in the footer writer's output.
#   Static argument validation (candidate present and executable,
#   CA_TIMEOUT numeric, timeout(1) present) happens BEFORE any record
#   path is touched; a usage error exits 2 and leaves a previous record's
#   bytes unchanged.
#   die_record leaves RECORD_FINISHED=0 when its FAIL footer did not
#   land, so finish_incomplete still runs (append INCOMPLETE, or clobber
#   a foreign file in place).
#
# Consumers run as a background job (setsid + timeout, wait in this shell)
# so a trap can kill the in-flight process group without waiting out the
# consumer budget. Block bodies run under bash -e -o pipefail -c.
# The consumer inherits EIGS/EIGENSCRIPT/EIGS_DIR/EIGENSCRIPT_DIR/
# EIGENSCRIPT_BIN (and EIGENSCRIPT_GFX only when the candidate actually
# has gfx) and the shim PATH; every CA_* name is unset in that
# environment. run_cleanup removes the run's scratch on every exit path.
#
# Residuals stated in the record header (not fixed here):
#   - any same-uid consumer that finds the shim script and reads it can
#     still recover the call-log path; the evidence is non-accidental,
#     not adversary-proof.
#   - a missing tool referenced inside a called script (not in PREREQS
#     and not a top-level token) still shows as a generic FAIL.
#   - ouroboros aot/build.sh keys libeigsrt.a on pwd -P of $EIGS_DIR/src,
#     so every run rebuilds against the per-run overlay path and leaves
#     aot/build/.libsrc stamped with a dead path. Known cost of the
#     overlay; not a bug. DMG#73 (hard-coded sibling path) is visible
#     via sibling_binary_present=, not worked around.
#   - SWALLOWED on an all-negative suite: a suite whose every candidate
#     call expects rc≠0 must include one positive invocation.
#   - a row-wide cand_calls count cannot certify WHICH work the candidate
#     did when an absolute-path subprocess then accepts with another
#     runtime after one candidate setup call.
#   - stdin-fed programs and `eigenscript --test` count as probe; no
#     real consumer uses them.
#   - variant derivation is by TOKEN, not by call site: a name that only
#     ever appears in prose, a comment, a JSON blob or a release-asset
#     filename still enters the set and makes the row UNRUNNABLE until
#     the operator supplies that candidate. Measured against the real
#     ecosystem on 2026-09-21: ouroboros yields eigenscript-src (a
#     Dockerfile path), eigenscript-aot-compiler-engineer (a skill name
#     in CLAUDE.md), eigenscript-probe / eigenscript-original /
#     eigenscript-missing-reuse (bench JSON); iLambdaAi yields
#     eigenscript-full-from-env (a comment) and eigenscript-full-linux-x86
#     (a release asset URL); Tidepool yields eigenscript-gfx-binary (a
#     usage line). Fail-closed and named beats a silent stale-PATH PASS
#     (#1213), but narrowing this to invocation sites is open work.
#   - the unwritable-directory plant cannot be planted as uid 0. As root
#     the self-test drops to an unprivileged user; with no runuser/setpriv
#     + nobody, or when a probe under that user fails, the plant and its
#     transverse row SKIP BY NAME and the final line reports skipped=N.
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
  [EigenMiniSat]="python3 -m unittest discover -s benchmarks -p 'test_*.py' && bash tests/run_smoke.sh && bash tests/run_proof_check.sh && eigenscript minisat.eigs --proof-bench --size 1"
  [EigenGauntlet]="bash tests/run_smoke.sh"
)

# Tools a consumer's command needs that are not the candidate. Keyed by
# repo name; also unioned with top-level tokens of the command itself
# (go/java/python3/make). A missing tool is UNRUNNABLE|prereq:<tool>,
# not a candidate regression (mechanical-gates §170).
declare -A PREREQS=(
  [eddy]="go java"
  [EigenMiniSat]="drat-trim"
  [dynamics]="gfx"
)

# Declared consumer set. plan and run FAIL by name when a member is absent
# from the scanned inventory, or when a pinning repo is present but not
# in this list (the declaration must be updated deliberately). Fixtures
# skip this list unless $ECO/.ca_expected names one. The previous
# committed record's row count is a second floor (reports/consumer_acceptance/*.record,
# newest).
EXPECTED_CONSUMERS=(
  DeslanStudio
  DMG
  dynamics
  eddy
  eigen-edit
  EigenGauntlet
  EigenMiniSat
  EigenRegex
  eigen-sheet
  iLambdaAi
  liferaft
  ouroboros
  phugoid
  polymethod
  tidelog
  Tidepool
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
# First-workflow-wins: prefer ci.yml, then tests.yml, then test.yml. If none
# of those has a runCmd and MORE THAN ONE other workflow does, the row is
# UNRUNNABLE|ambiguous-workflow:<names> (ACCEPT_AMBIGUOUS is set, rc 1).
ACCEPT_WF=""
ACCEPT_CMD=""
ACCEPT_AMBIGUOUS=""
accept_cmd_of() {
  local r wfdir f p cmd base
  r="$1"
  wfdir="$ECO/$r/.github/workflows"
  local -a others
  ACCEPT_WF=""
  ACCEPT_CMD=""
  ACCEPT_AMBIGUOUS=""
  # CA-GUARD:workflow-prefer
  for p in ci.yml tests.yml test.yml; do
    f="$wfdir/$p"
    [ -f "$f" ] || continue
    if cmd="$(python3 "$HERE/tools/_extract_runcmd.py" "$f")"; then
      ACCEPT_WF="$p"
      ACCEPT_CMD="$cmd"
      return 0
    fi
  done
  others=()
  for f in "$wfdir"/*.y*ml; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    case "$base" in
      ci.yml|tests.yml|test.yml) continue ;;
    esac
    if python3 "$HERE/tools/_extract_runcmd.py" "$f" >/dev/null 2>&1; then
      others+=("$base")
    fi
  done
  if [ "${#others[@]}" -eq 1 ]; then
    ACCEPT_WF="${others[0]}"
    ACCEPT_CMD="$(python3 "$HERE/tools/_extract_runcmd.py" "$wfdir/${others[0]}")" || return 1
    return 0
  fi
  if [ "${#others[@]}" -gt 1 ]; then
    local IFS=','
    ACCEPT_AMBIGUOUS="${others[*]}"
    ACCEPT_WF=""
    return 1
  fi
  return 1
}

# Executable names this consumer invokes: eigenscript, or
# eigenscript-[a-z0-9-]+ (multi-hyphen included). Derived from EVERY text
# file in the checkout (grep -rIl, no type allowlist, minus .git), never
# typed. Bind locals first, then derive — `local r=... dir=$r` expands $r
# before the local binds it, and under set -u a run_one subshell dies
# with `r: unbound variable` and yields "" (the derived set is then never
# consulted).
variants_of() {
  local r n out="" seen=" " dir raw="" f
  r="${1:-}"
  dir="${ECO:-}/$r"
  [ -d "$dir" ] || { printf '%s' ""; return 0; }
  raw=""
  while IFS= read -r f || [ -n "$f" ]; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    raw="${raw}$(grep -hEo 'eigenscript(-[a-z0-9]+)*' "$f" 2>/dev/null || true)"$'\n'
  done <<< "$(grep -rIl --exclude-dir=.git . "$dir" 2>/dev/null || true)"
  while IFS= read -r n || [ -n "$n" ]; do
    [ -z "$n" ] && continue
    case "$n" in
      eigenscript) ;;
      eigenscript-[a-z0-9]*) ;;
      *) continue ;;
    esac
    case "$seen" in
      *" $n "*) continue ;;
    esac
    seen="$seen$n "
    out="${out:+$out }$n"
  done <<< "$raw"
  printf '%s' "$out"
}

# For a DECLARED command, every bash/sh/python3/python file token must
# exist, not only the first token of each segment. `python3 -m unittest
# discover -s DIR` checks DIR as a directory. Compound commands (&& / ;)
# are checked segment by segment. Prints the first missing path (relative
# to the repo) or nothing. Mechanical-gates §170: a declared fallback is
# a hand-typed claim and is verified like a derived one.
_declared_missing_one() {
  local repo="$1" file="$2" want="${3:-file}"
  [ -n "$file" ] || return 1
  case "$file" in
    /*)
      if [ "$want" = dir ]; then
        [ -d "$file" ] || { printf '%s' "$file"; return 0; }
      else
        [ -f "$file" ] || { printf '%s' "$file"; return 0; }
      fi
      ;;
    *)
      if [ "$want" = dir ]; then
        [ -d "$repo/$file" ] || { printf '%s' "$file"; return 0; }
      else
        [ -f "$repo/$file" ] || { printf '%s' "$file"; return 0; }
      fi
      ;;
  esac
  return 1
}

declared_missing_file() {
  local repo="$1" cmd="$2"
  local norm piece tok nxt rest i
  local -a toks
  norm="${cmd//&&/$'\n'}"
  norm="${norm//;/$'\n'}"
  while IFS= read -r piece || [ -n "$piece" ]; do
    piece="${piece#"${piece%%[![:space:]]*}"}"
    piece="${piece%"${piece##*[![:space:]]}"}"
    [ -z "$piece" ] && continue
    # CA-GUARD:noglob-split
    local glob_off=0
    case "$-" in *f*) glob_off=1 ;; esac
    set -f
    # shellcheck disable=SC2086
    set -- $piece
    toks=("$@")
    [ "$glob_off" -eq 0 ] && set +f
    i=0
    while [ "$i" -lt "${#toks[@]}" ]; do
      tok="${toks[$i]}"
      nxt=""
      [ $((i + 1)) -lt "${#toks[@]}" ] && nxt="${toks[$((i + 1))]}"
      case "$tok" in
        bash|sh)
          case "$nxt" in
            ''|-*) ;;
            *)
              if _declared_missing_one "$repo" "$nxt" file; then
                return 0
              fi
              ;;
          esac
          ;;
        python3|python)
          if [ "$nxt" = "-m" ]; then
            rest=$((i + 2))
            if [ "$rest" -lt "${#toks[@]}" ] && [ "${toks[$rest]}" = "unittest" ]; then
              rest=$((rest + 1))
              while [ "$rest" -lt "${#toks[@]}" ]; do
                if [ "${toks[$rest]}" = "-s" ] && [ $((rest + 1)) -lt "${#toks[@]}" ]; then
                  if _declared_missing_one "$repo" "${toks[$((rest + 1))]}" dir; then
                    return 0
                  fi
                  break
                fi
                rest=$((rest + 1))
              done
            fi
          else
            case "$nxt" in
              ''|-*) ;;
              *)
                if _declared_missing_one "$repo" "$nxt" file; then
                  return 0
                fi
                ;;
            esac
          fi
          ;;
        *)
          case "$tok" in
            */*|*.sh|*.py|*.eigs)
              if _declared_missing_one "$repo" "$tok" file; then
                return 0
              fi
              ;;
          esac
          ;;
      esac
      i=$((i + 1))
    done
  done <<< "$norm"
  return 0
}

# First missing tool from PREREQS[name], fixture .ca_prereqs, and top-level
# command tokens (go/java/python3/python/make). `gfx` is a candidate
# capability (not a PATH tool): missing it is prereq:gfx-build. Prints
# the tool; rc 0 if something is missing, 1 if every named tool is present.
missing_prereq() {
  local name="$1" cmd="$2"
  local tools="" t piece first
  tools="${PREREQS[$name]:-}"
  if [ -f "${ECO:-}/.ca_fixture" ] && [ -f "$ECO/$name/.ca_prereqs" ]; then
    tools="$tools $(tr '\n' ' ' < "$ECO/$name/.ca_prereqs")"
  fi
  case "$cmd" in
    *gfx*) tools="$tools gfx" ;;
  esac
  local norm="${cmd//&&/$'\n'}"
  norm="${norm//;/$'\n'}"
  while IFS= read -r piece || [ -n "$piece" ]; do
    piece="${piece#"${piece%%[![:space:]]*}"}"
    [ -z "$piece" ] && continue
    # CA-GUARD:noglob-split
    local glob_off=0
    case "$-" in *f*) glob_off=1 ;; esac
    set -f
    # shellcheck disable=SC2086
    set -- $piece
    first="${1:-}"
    [ "$glob_off" -eq 0 ] && set +f
    case "$first" in
      go|java|python3|python|make) tools="$tools $first" ;;
    esac
  done <<< "$norm"
  for t in $tools; do
    [ -z "$t" ] && continue
    if [ "$t" = gfx ]; then
      # CA-GUARD:gfx-prereq
      if [ "${CAND_HAS_GFX:-0}" != 1 ]; then
        if [ "${CAND_HAS_GFX:-0}" = unknown ]; then
          printf 'gfx-build (probe rc %s)' "${CAND_GFX_RC:-?}"
        else
          printf 'gfx-build'
        fi
        return 0
      fi
      continue
    fi
    if ! command -v "$t" >/dev/null 2>&1; then
      printf '%s' "$t"
      return 0
    fi
  done
  return 1
}

# Walk up from the candidate until a directory whose src/eigenscript is
# that same file (-ef). Empty CAND_TREE is a bare binary: if $ECO/EigenScript
# also exists, run refuses (exit 2) rather than letting EIGS_DIR-fallback
# consumers do their tree work against the sibling.
derive_candidate_tree() {
  local cand="$1" dir
  CAND_TREE=""
  dir="$(cd "$(dirname "$cand")" && pwd)" || return 1
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -e "$dir/src/eigenscript" ] && [ "$dir/src/eigenscript" -ef "$cand" ]; then
      CAND_TREE="$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# Executable regular file, distinct from the candidate. Used before the
# wave (header) and after (footer); no→yes when a consumer created one.
sibling_is_present() {
  local p="${ECO:-}/EigenScript/src/eigenscript"
  if [ -f "$p" ] && [ -x "$p" ] && [ ! "$p" -ef "${CAND_ABS:-/}" ]; then
    printf 'yes'
  else
    printf 'no'
  fi
}

# Overlay of the candidate tree under the run scratch: a COPY of src/,
# lib/, and top-level files (including dotfiles a build may read, e.g.
# .gitignore; never .git). Dirs are copied with cp -rL so writes through
# a symlink cannot reach outside the overlay. A link that cannot be
# dereferenced is skipped and noted (overlay_skipped=). src/eigenscript
# is replaced by the counting shim. Never mutates the real tree.
build_candidate_overlay() {
  local src="$1" dst="$2" item base s
  CAND_OVERLAY=""
  OVERLAY_SKIPPED=""
  [ -n "$src" ] && [ -d "$src" ] || return 1
  mkdir -p "$dst"
  # CA-GUARD:overlay-copy
  overlay_copy_dir() {
    local from="$1" to="$2" tag="$3" s base first_ok=1
    if fixture_fault && [ "${CA_FAULT:-}" = overlay_partial ] && [ "$tag" = src ]; then
      mkdir -p "$to/data"
      first_ok=0
    elif cp -rL "$from" "$to" 2>/dev/null; then
      return 0
    else
      first_ok=0
    fi
    if [ "$first_ok" -eq 0 ]; then
      mkdir -p "$to"
      for s in "$from"/*; do
        [ -e "$s" ] || { OVERLAY_SKIPPED="${OVERLAY_SKIPPED:+$OVERLAY_SKIPPED }$tag/$(basename "$s")"; continue; }
        base="$(basename "$s")"
        # CA-GUARD:overlay-retry-rm
        rm -rf "$to/$base"
        cp -rL "$s" "$to/$base" 2>/dev/null || \
          OVERLAY_SKIPPED="${OVERLAY_SKIPPED:+$OVERLAY_SKIPPED }$tag/$base"
      done
    fi
  }
  if [ -d "$src/src" ]; then
    overlay_copy_dir "$src/src" "$dst/src" src
  else
    mkdir -p "$dst/src"
  fi
  rm -f "$dst/src/eigenscript"
  cp "$SHIM/eigenscript" "$dst/src/eigenscript"
  chmod +x "$dst/src/eigenscript"
  if [ -d "$src/lib" ]; then
    overlay_copy_dir "$src/lib" "$dst/lib" lib
  fi
  local nullglob_was=0 dotglob_was=0
  shopt -q nullglob && nullglob_was=1
  shopt -q dotglob && dotglob_was=1
  shopt -s nullglob dotglob
  for item in "$src"/*; do
    base="$(basename "$item")"
    case "$base" in
      .|..|.git|src|lib) continue ;;
    esac
    if [ -f "$item" ]; then
      cp -a "$item" "$dst/$base"
    elif [ -L "$item" ]; then
      cp -L "$item" "$dst/$base" 2>/dev/null || cp -a "$item" "$dst/$base"
    fi
  done
  if [ "$dotglob_was" -eq 0 ]; then
    shopt -u dotglob
  fi
  if [ "$nullglob_was" -eq 0 ]; then
    shopt -u nullglob
  fi
  CAND_OVERLAY="$dst"
}

# Declared expected names for this ECO. Fixtures skip EXPECTED_CONSUMERS
# unless $ECO/.ca_expected lists them. Production always uses the table.
# Record floor: lexically greatest YYYY-MM-DD-… filename, never mtime.
# Fixtures read $ECO/reports/consumer_acceptance when that dir exists so
# plant B3 can reach the floor; CA_FAULT=record_floor=N overrides.
load_expected_list() {
  EXPECTED_LIST=()
  RECORD_FLOOR=0
  if [ -f "${ECO:-}/.ca_expected" ]; then
    local n
    while IFS= read -r n || [ -n "$n" ]; do
      n="${n#"${n%%[![:space:]]*}"}"
      n="${n%"${n##*[![:space:]]}"}"
      [ -z "$n" ] && continue
      EXPECTED_LIST+=("$n")
    done < "$ECO/.ca_expected"
  elif [ ! -f "${ECO:-}/.ca_fixture" ]; then
    EXPECTED_LIST=("${EXPECTED_CONSUMERS[@]}")
  fi
  local rec_dir="" f newest="" rows b nb
  if fixture_fault; then
    case "${CA_FAULT:-}" in
      record_floor=*)
        rec_dir="__fault__"
        rows="${CA_FAULT#record_floor=}"
        ;;
    esac
  fi
  if [ -z "$rec_dir" ]; then
    if [ -f "${ECO:-}/.ca_fixture" ] && [ -d "${ECO:-}/reports/consumer_acceptance" ]; then
      rec_dir="$ECO/reports/consumer_acceptance"
    elif [ ! -f "${ECO:-}/.ca_fixture" ]; then
      rec_dir="$HERE/reports/consumer_acceptance"
    fi
  fi
  local computed=0
  if [ "$rec_dir" = "__fault__" ]; then
    computed="${rows:-0}"
  elif [ -n "$rec_dir" ]; then
    newest=""
    for f in "$rec_dir"/*.record; do
      [ -f "$f" ] || continue
      b="$(basename "$f")"
      if [ -z "$newest" ]; then
        newest="$f"
      else
        nb="$(basename "$newest")"
        if [ "$b" \> "$nb" ]; then
          newest="$f"
        fi
      fi
    done
    if [ -n "$newest" ]; then
      rows="$(grep -c '^row|' "$newest" 2>/dev/null || true)"
      computed="${rows:-0}"
    fi
  fi
  # CA-GUARD:record-floor
  RECORD_FLOOR="$computed"
}

# Scan ECO into GATE_* / SKIP_* arrays. Prints the plan listing iff $1=print.
# Does not print a verdict -- callers do. Diagnostics never go through stdout
# of a function whose result is captured (mechanical-gates: no $(( $(fn) ))).
# Globals: GATE_NAMES/PINS/CMDS/KINDS/WFS/VARS, SKIP_NAMES/PINS/REASONS, INVENTORY, GAPS.
scan_inventory() {
  local verbose=0
  [ "${1:-}" = print ] && verbose=1
  # Self-test plant B: drop a snapshotted consumer's checkout BEFORE the
  # scan so the declared-set floor fires (not only a later UNRUNNABLE).
  # The .ca_fixture marker is the only thing that unlocks this, so a
  # stray env var cannot delete a sibling (mechanical-gates §168).
  if [ -n "${CA_DROP_BEFORE:-}" ] && [ -f "${ECO:-}/.ca_fixture" ]; then
    rm -rf "$ECO/$CA_DROP_BEFORE"
  fi
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
  GATE_NAMES=(); GATE_PINS=(); GATE_CMDS=(); GATE_KINDS=(); GATE_WFS=(); GATE_VARS=()
  SKIP_NAMES=(); SKIP_PINS=(); SKIP_REASONS=()
  INVENTORY=0
  GAPS=0
  FLOOR_FAIL=0
  FLOOR_WHY=""
  load_expected_list
  local r pin cmd d kind gap_why miss vnames wf
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
    kind=""
    gap_why=""
    wf=""
    vnames="$(variants_of "$r")"
    if accept_cmd_of "$r"; then
      cmd="$ACCEPT_CMD"
      kind=derived
      wf="$ACCEPT_WF"
    elif [ -n "$ACCEPT_AMBIGUOUS" ]; then
      kind=ambiguous
      GAPS=$((GAPS + 1))
      gap_why="ambiguous-workflow:${ACCEPT_AMBIGUOUS}"
      wf="$ACCEPT_AMBIGUOUS"
    elif [ -n "${DECLARED[$r]:-}" ]; then
      cmd="${DECLARED[$r]}"
      kind=declared
    elif [ -f "${ECO:-}/.ca_fixture" ] && [ -f "$ECO/$r/.ca_declared" ]; then
      IFS= read -r cmd < "$ECO/$r/.ca_declared" || true
      kind=declared
    else
      kind=gap
      GAPS=$((GAPS + 1))
      gap_why="pins the runtime but no acceptance command could be derived"
    fi
    if [ "$kind" = declared ]; then
      miss=""
      # CA-GUARD:declared-file
      miss="$(declared_missing_file "$ECO/$r" "$cmd")"
      if [ -n "$miss" ]; then
        kind=gap
        cmd=""
        GAPS=$((GAPS + 1))
        gap_why="declared command's file does not exist: $miss"
      fi
    fi
    GATE_KINDS+=("$kind")
    GATE_NAMES+=("$r")
    GATE_PINS+=("$pin")
    GATE_CMDS+=("$cmd")
    GATE_WFS+=("$wf")
    GATE_VARS+=("$vnames")
    INVENTORY=$((INVENTORY + 1))
    if [ "$verbose" -eq 1 ]; then
      if [ "$kind" = declared ]; then
        say "  gate   $r  ($pin)  [declared -- CI has no runCmd to derive]"
        say "         $ $cmd"
      elif [ "$kind" = gap ] || [ "$kind" = ambiguous ]; then
        say "  GAP    $r  ($pin) -- ${gap_why:-pins the runtime but no acceptance command could be derived}"
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
      if [ -n "$wf" ] && [ "$kind" = derived ]; then
        say "  workflow|$r|$wf"
      fi
      say "  variants|$r|${vnames:-eigenscript}"
    fi
  done
  if [ "$nullglob_was" -eq 0 ]; then
    shopt -u nullglob
  fi
  # CA-GUARD:expected-floor
  # Declared names absent from disk, and pinning names not in the declared
  # set, are FAILs. Missing declared consumers are added as UNRUNNABLE rows
  # so examined == inventory still holds and the name is in the record.
  if [ "${#EXPECTED_LIST[@]}" -gt 0 ]; then
    local e found gi extra
    for e in "${EXPECTED_LIST[@]}"; do
      found=0
      for gi in "${GATE_NAMES[@]+"${GATE_NAMES[@]}"}" "${SKIP_NAMES[@]+"${SKIP_NAMES[@]}"}"; do
        [ "$gi" = "$e" ] && found=1 && break
      done
      if [ "$found" -eq 0 ]; then
        GATE_KINDS+=("missing-declared")
        GATE_NAMES+=("$e")
        GATE_PINS+=("absent")
        GATE_CMDS+=("")
        GATE_WFS+=("")
        GATE_VARS+=("")
        INVENTORY=$((INVENTORY + 1))
        GAPS=$((GAPS + 1))
        FLOOR_FAIL=1
        FLOOR_WHY="${FLOOR_WHY:+$FLOOR_WHY; }declared consumer absent: $e"
        if [ "$verbose" -eq 1 ]; then
          say "  GAP    $e  -- declared consumer absent"
        fi
      fi
    done
    gi=0
    while [ "$gi" -lt "${#GATE_NAMES[@]}" ]; do
      extra="${GATE_NAMES[$gi]}"
      found=0
      for e in "${EXPECTED_LIST[@]}"; do
        [ "$e" = "$extra" ] && found=1 && break
      done
      if [ "$found" -eq 0 ] && [ "${GATE_KINDS[$gi]}" != "missing-declared" ]; then
        GAPS=$((GAPS + 1))
        FLOOR_FAIL=1
        FLOOR_WHY="${FLOOR_WHY:+$FLOOR_WHY; }undeclared consumer present: $extra"
        GATE_KINDS[$gi]=undeclared
        if [ "$verbose" -eq 1 ]; then
          say "  GAP    $extra  -- present on disk but not declared"
        fi
      fi
      gi=$((gi + 1))
    done
  fi
  if [ "${RECORD_FLOOR:-0}" -gt 0 ] && [ "$INVENTORY" -lt "$RECORD_FLOOR" ]; then
    FLOOR_FAIL=1
    FLOOR_WHY="${FLOOR_WHY:+$FLOOR_WHY; }inventory $INVENTORY < record floor $RECORD_FLOOR"
    GAPS=$((GAPS + 1))
  fi
  if [ "$verbose" -eq 1 ]; then
    say "inventory_floor expected=${#EXPECTED_LIST[@]} scanned=$INVENTORY record_floor=${RECORD_FLOOR:-0}"
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
    if [ "${FLOOR_FAIL:-0}" -ne 0 ]; then
      say "VERDICT: FAIL -- inventory floor: ${FLOOR_WHY:-gaps}"
    else
      say "VERDICT: FAIL -- $GAPS of $INVENTORY consumers have no derivable acceptance command"
    fi
    FAILED=1; return
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
RECORD_LOCKED=0
RECORD_LOCKDIR=""
RECORD_LOCK_NOTE=""
HEADER_WRITTEN=0
STDOUT_VERDICT_EMITTED=0
EXAMINED=0
INVENTORY=0
CAND_ABS=""
CAND_VER=""
CAND_TREE=""
CAND_OVERLAY=""
RESOLVED=""
CALL_LOG=""
PRIV=""
CAND_HAS_GFX=0
CAND_GFX_RC=""
OVERLAY_SKIPPED=""
SIBLING_BEFORE=no
SIBLING_AFTER=no
SIBLING_PRESENT=no
LAST_CALLS=0
LAST_OK=0
LAST_FAIL=0
LAST_PREREQ=""
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

# Idempotent stdout verdict. Every run-mode exit path that has a record
# lifecycle (PASS/FAIL/INCOMPLETE) goes through here once. The VERDICT
# line stays EXACT ("VERDICT: FAIL"); a floor failure is named on its own
# `inventory floor: <why>` line before the verdict and in the footer.
emit_stdout_verdict() {
  [ "${STDOUT_VERDICT_EMITTED:-0}" -eq 1 ] && return 0
  verdict_line "$1"
  STDOUT_VERDICT_EMITTED=1
}

# HUP-after-rename lands here: RECORD_FINISHED was set before mv, so the
# trap treats the run as complete and must still print VERDICT.
emit_stdout_verdict_for_rc() {
  # CA-GUARD:stdout-verdict
  case "${RUN_RC:-1}" in
    0) emit_stdout_verdict PASS ;;
    1) emit_stdout_verdict FAIL ;;
    *) emit_stdout_verdict INCOMPLETE ;;
  esac
}

fixture_fault() {
  [ -f "${ECO:-}/.ca_fixture" ] || return 1
  [ -n "${CA_FAULT:-}" ] || return 1
  return 0
}

# Exclusive lock on the record path. mkdir is the portable atomic; the
# holder file names the live pid so a dead holder's dir is reclaimed.
acquire_record_lock() {
  local lockdir="${RECORD}.lock.d" holder_pid="" holder_id="" tries=0
  RECORD_LOCKDIR="$lockdir"
  RECORD_LOCK_NOTE=""
  RECORD_LOCKED=0
  while [ "$tries" -lt 5 ]; do
    if mkdir "$lockdir" 2>/dev/null; then
      printf 'pid=%s\nrun_id=%s\n' "$$" "${RUN_ID:-unknown}" > "$lockdir/holder" || true
      RECORD_LOCKED=1
      return 0
    fi
    if [ ! -d "$lockdir" ]; then
      # Parent unwritable / missing -- not "busy". Later writes fail closed.
      RECORD_LOCKDIR=""
      return 0
    fi
    if [ ! -f "$lockdir/holder" ]; then
      sleep 0.05 2>/dev/null || sleep 1
    fi
    holder_pid=""
    holder_id=""
    if [ -f "$lockdir/holder" ]; then
      holder_pid="$(grep '^pid=' "$lockdir/holder" 2>/dev/null | head -1 | cut -d= -f2-)"
      holder_id="$(grep '^run_id=' "$lockdir/holder" 2>/dev/null | head -1 | cut -d= -f2-)"
    fi
    if [ -n "$holder_pid" ] && kill -0 "$holder_pid" 2>/dev/null; then
      say "consumer_acceptance: record busy (held by run ${holder_id:-unknown}, pid $holder_pid)"
      RECORD_LOCKDIR=""
      return 1
    fi
    RECORD_LOCK_NOTE="reclaimed stale lock (held by run ${holder_id:-unknown}, pid ${holder_pid:-dead})"
    rm -rf "$lockdir"
    tries=$((tries + 1))
  done
  say "consumer_acceptance: record busy (held by run ${holder_id:-unknown}, pid ${holder_pid:-unknown})"
  RECORD_LOCKDIR=""
  return 1
}

release_record_lock() {
  if [ "${RECORD_LOCKED:-0}" -eq 1 ] && [ -n "${RECORD_LOCKDIR:-}" ]; then
    rm -rf "$RECORD_LOCKDIR"
  fi
  RECORD_LOCKED=0
  RECORD_LOCKDIR=""
}

# The single writer. Reads stdin. Returns 1 on any failure; sets
# RECORD_WRITE_ERR. mode is append | replace; optional tag names the
# temp file (footer uses "rewrite" so a PATH-shim can target the final
# rename). Callers check: write_record ... || die_record "why".
# Replace temps live in the record's own directory (mktemp next to
# $RECORD, then mv). run_cleanup removes a leftover rewrite temp if a
# signal arrives in the pause-before-rename window.
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
      # CA-GUARD:append-owned
      # The ONLY file we may append to without our run_id is a ZERO-BYTE one
      # (the in-place clobber after truncate). A nonempty file with no run_id
      # line is somebody else's content (round-4 residual R11: a replacement
      # INCOMPLETE record with no run_id was accepted and the final record read
      # PASS with rows missing). And never through a symlink (R7).
      if [ -L "$RECORD" ]; then
        RECORD_WRITE_ERR="record path is a symlink"
        return 1
      fi
      if [ -s "$RECORD" ] \
         && ! grep -Fx "run_id=${RUN_ID}" "$RECORD" >/dev/null 2>&1; then
        RECORD_WRITE_ERR="record not ours"
        return 1
      fi
      if ! cat >> "$RECORD"; then
        RECORD_WRITE_ERR="cannot append to $RECORD"
        return 1
      fi
      return 0
      ;;
    replace)
      # CA-GUARD:tmp-beside-record
      dir="$(dirname "$RECORD")"
      tmp="$(mktemp "$dir/.$(basename "$RECORD").${tag}.XXXXXX")" || {
        RECORD_WRITE_ERR="cannot create record temp next to $RECORD"
        return 1
      }
      RECORD_REWRITE_TMP="$tmp"
      if fixture_fault && [ "${CA_FAULT:-}" = show_tmp ]; then
        say "record_tmp_dir=$(dirname "$tmp")"
      fi
      if ! cat > "$tmp"; then
        RECORD_WRITE_ERR="cannot write record temp at $tmp"
        rm -f "$tmp"
        RECORD_REWRITE_TMP=""
        return 1
      fi
      if fixture_fault && [ "${CA_FAULT:-}" = pause_before_rename ] && [ "$tag" = rewrite ]; then
        sleep 30 &
        wait $! || true
      fi
      if ! mv "$tmp" "$RECORD"; then
        RECORD_WRITE_ERR="cannot rename record temp onto $RECORD"
        rm -f "$tmp"
        RECORD_REWRITE_TMP=""
        return 1
      fi
      RECORD_REWRITE_TMP=""
      if [ "$tag" = rewrite ]; then
        # CA-GUARD:finished-before-rename
        RECORD_FINISHED=1
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
  local why="$1" footer_ok=0
  say "consumer_acceptance: $why${RECORD_WRITE_ERR:+ ($RECORD_WRITE_ERR)}"
  if [ -n "${RECORD:-}" ] && [ -f "${RECORD:-}" ] && [ "${RECORD_FINISHED:-0}" -eq 0 ]; then
    if [ -n "${RUN_ID:-}" ] && grep -Fx "run_id=${RUN_ID}" "$RECORD" >/dev/null 2>&1; then
      if write_record_footer FAIL COMPLETE; then
        footer_ok=1
      else
        say "consumer_acceptance: also failed to write FAIL footer"
      fi
    fi
  fi
  emit_stdout_verdict FAIL
  # CA-GUARD:die-record-flag
  # Leave RECORD_FINISHED=0 when the footer did not land, so the EXIT
  # trap's finish_incomplete still appends INCOMPLETE or clobbers a
  # foreign file. Never a foreign PASS at the path.
  if [ "$footer_ok" -eq 1 ]; then
    RECORD_FINISHED=1
  fi
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
  # CA-GUARD:finish-incomplete
  # CA-GUARD:verdict-from-file
  # Re-read the file rather than trusting RECORD_FINISHED: a signal after
  # a successful footer mv is a completed run even if the flag was not
  # yet stored; a signal before the mv is INCOMPLETE.
  if [ -n "${RECORD:-}" ] && [ -f "${RECORD:-}" ]; then
    # Trust a COMPLETE footer only if it carries probe_rc= (the real
    # write_record_footer). fail_footer forges PASS without that field.
    if grep -q '^status=COMPLETE$' "$RECORD" 2>/dev/null \
       && grep -q '^probe_rc=' "$RECORD" 2>/dev/null; then
      if grep -qx 'VERDICT: PASS' "$RECORD"; then
        RECORD_FINISHED=1
        RUN_RC=0
        return
      fi
      if grep -qx 'VERDICT: FAIL' "$RECORD"; then
        RECORD_FINISHED=1
        RUN_RC=1
        return
      fi
    fi
  fi
  [ "${RECORD_FINISHED:-0}" -eq 1 ] && return
  [ -n "${RECORD:-}" ] && [ -f "$RECORD" ] || return
  if [ -n "${RUN_ID:-}" ] && grep -Fx "run_id=${RUN_ID}" "$RECORD" >/dev/null 2>&1; then
    if grep -q '^VERDICT: INCOMPLETE$' "$RECORD" \
       && ! grep -q '^VERDICT: PASS$' "$RECORD" \
       && ! grep -q '^VERDICT: FAIL$' "$RECORD"; then
      emit_stdout_verdict INCOMPLETE
      RECORD_FINISHED=1
      return
    fi
    write_record append <<EOF || say "consumer_acceptance: failed to write INCOMPLETE footer"
status=INCOMPLETE
examined=${EXAMINED:-0}
inventory=${INVENTORY:-0} examined=${EXAMINED:-0}
VERDICT: INCOMPLETE
EOF
    emit_stdout_verdict INCOMPLETE
  elif [ "${HEADER_WRITTEN:-0}" -eq 1 ]; then
    # We claimed the path, then lost it: clobber so a foreign PASS cannot
    # survive. If we never wrote a header, leave the previous file (the
    # invalidate guard is what destroys a stale PASS before we start).
    clobber_record_in_place || say "consumer_acceptance: failed to clobber stale record at $RECORD"
    emit_stdout_verdict INCOMPLETE
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
  if [ -n "${RECORD_REWRITE_TMP:-}" ]; then
    rm -f "$RECORD_REWRITE_TMP"
    RECORD_REWRITE_TMP=""
  fi
  if [ -n "${CA_LOGS:-}" ] && [ -n "${WORK:-}" ] && [ -d "${WORK:-}/logs" ]; then
    mkdir -p "$CA_LOGS"
    cp -a "$WORK/logs/." "$CA_LOGS/" 2>/dev/null || true
  fi
  if [ -n "${WORK:-}" ] && [ -d "${WORK:-}" ]; then
    # CA-GUARD:scratch-cleanup
    rm -rf "$WORK"
    WORK=""
  fi
  if [ -n "${PRIV:-}" ] && [ -d "${PRIV:-}" ]; then
    rm -rf "$PRIV"
    PRIV=""
  fi
  release_record_lock
}

install_run_traps() {
  # Snapshot RECORD_FINISHED before cleanup: finish_incomplete sets the
  # flag after writing INCOMPLETE, which is not a completed run. When
  # the flag was already 1 (HUP-after-rename), emit the stdout verdict
  # the finalizer did not reach.
  trap 'run_cleanup
    if [ "${RECORD_FINISHED:-0}" -eq 1 ]; then
      emit_stdout_verdict_for_rc
      if [ -n "${RECORD:-}" ] && [ -f "$RECORD" ] && grep -qx "VERDICT: PASS" "$RECORD"; then
        exit 0
      fi
      if [ -n "${RECORD:-}" ] && [ -f "$RECORD" ] && grep -qx "VERDICT: FAIL" "$RECORD"; then
        exit 1
      fi
      exit 2
    else
      exit 2
    fi' INT TERM HUP
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
# Never truncate THROUGH a symlink (R7): unlink the link first and create
# a regular file, so a victim at the other end keeps its bytes.
clobber_record_in_place() {
  # CA-GUARD:clobber-no-follow
  if [ -L "$RECORD" ]; then
    rm -f "$RECORD" || {
      RECORD_WRITE_ERR="cannot unlink symlink at $RECORD"
      return 1
    }
  fi
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
# Residual: any same-uid consumer that finds the shim script and reads it
# can still recover the call-log path; the evidence is non-accidental, not
# adversary-proof.
# Residual: a missing tool referenced inside a called script (not in
# PREREQS / top-level tokens) still shows as a generic FAIL.
# Overlay is a COPY of src/, lib/, and top-level files (never .git);
# directories are copied with cp -rL. A symlink that cannot be
# dereferenced is skipped (overlay_skipped=).
# ouroboros aot/build.sh keys libeigsrt.a on pwd -P of \$EIGS_DIR/src, so
# every run rebuilds against the per-run overlay path and leaves
# aot/build/.libsrc stamped with a dead path (the next local build
# rebuilds again). Known cost of the overlay, not a bug.
# When sibling_binary_present=yes, consumers with hard-coded sibling
# paths (DMG#73) may have used \$ECO/EigenScript/src/eigenscript; that is
# visible here, not worked around. sibling_binary_present is the value
# before the wave; sibling_binary_present_after is after. Counted only
# when \$ECO/EigenScript/src/eigenscript is an executable regular file
# distinct from the candidate.
# A bare candidate is refused (exit 2) when \$ECO/EigenScript exists;
# pass a tree candidate so EIGS_DIR is an overlay of the candidate.
# Residual: SWALLOWED on an all-negative suite -- a suite whose every
# candidate call expects rc≠0 must include one positive invocation.
# Residual: a row-wide cand_calls count cannot certify WHICH work the
# candidate did when an absolute-path subprocess then accepts with
# another runtime after one candidate setup call.
# Residual: stdin-fed programs and eigenscript --test count as probe;
# no real consumer uses them.
run_id=$RUN_ID
started=$STARTED
eco_root=${ECO:-PENDING}
block_shell=bash -e -o pipefail -c
candidate_path=${CAND_ABS:-PENDING}
candidate_version=PENDING
candidate_sha256=PENDING
candidate_tree=PENDING
candidate_full_path=${CAND_FULL_ABS:-}
candidate_full_version=PENDING
candidate_full_sha256=PENDING
candidate_gfx_path=${CAND_GFX_ABS:-}
candidate_gfx_version=PENDING
candidate_gfx_sha256=PENDING
eigenscript_resolved=${RESOLVED:-PENDING}
overlay=copy
overlay_skipped=PENDING
sibling_binary_present=PENDING
logs_dir=${CA_LOGS:-}
inventory=PENDING
examined=PENDING
status=INCOMPLETE
${RECORD_LOCK_NOTE:+note=$RECORD_LOCK_NOTE
}# row|name|pin|verdict|rc|duration_s|cand_calls=N|cand_ok=N|cand_fail=M|consumer_skips=N|sibling_binary_present=yes/no
VERDICT: INCOMPLETE
EOF
}

write_record_footer() {
  local verdict="$1" status="$2" line content n
  if [ ! -f "$RECORD" ]; then
    RECORD_WRITE_ERR="footer: $RECORD missing"
    return 1
  fi
  if fixture_fault && [ "${CA_FAULT:-}" = fail_footer ]; then
    printf '%s\n' \
      "run_id=$RUN_ID" \
      "status=COMPLETE" \
      "inventory=${INVENTORY:-0} examined=${EXAMINED:-0}" \
      "VERDICT: PASS" > "$RECORD"
    RECORD_WRITE_ERR="planted footer failure"
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
        candidate_sha256=PENDING)  printf 'candidate_sha256=%s\n' "${CAND_SHA:-}" ;;
        candidate_tree=PENDING)    printf 'candidate_tree=%s\n' "${CAND_TREE:-}" ;;
        candidate_full_version=PENDING) printf 'candidate_full_version=%s\n' "${CAND_FULL_VER:-}" ;;
        candidate_full_sha256=PENDING)  printf 'candidate_full_sha256=%s\n' "${CAND_FULL_SHA:-}" ;;
        candidate_gfx_version=PENDING)  printf 'candidate_gfx_version=%s\n' "${CAND_GFX_VER:-}" ;;
        candidate_gfx_sha256=PENDING)   printf 'candidate_gfx_sha256=%s\n' "${CAND_GFX_SHA:-}" ;;
        eigenscript_resolved=PENDING) printf 'eigenscript_resolved=%s\n' "${RESOLVED:-}" ;;
        sibling_binary_present=PENDING) printf 'sibling_binary_present=%s\n' "${SIBLING_BEFORE:-${SIBLING_PRESENT:-no}}" ;;
        overlay_skipped=PENDING)   printf 'overlay_skipped=%s\n' "${OVERLAY_SKIPPED:-}" ;;
        "VERDICT: INCOMPLETE")     verdict_line "$verdict" ;;
        VERDICT:*)                 ;; # drop any other verdict; we emit one
        *)                         printf '%s\n' "$line" ;;
      esac
    done < "$RECORD"
    printf 'probe_rc=%s\n' "${PROBE_RC:--}"
    printf 'sibling_binary_present_after=%s\n' "${SIBLING_AFTER:-${SIBLING_PRESENT:-no}}"
    if [ "${SIBLING_BEFORE:-no}" != "${SIBLING_AFTER:-${SIBLING_PRESENT:-no}}" ]; then
      printf 'sibling_binary_present_changed=%s→%s\n' "${SIBLING_BEFORE:-no}" "${SIBLING_AFTER:-${SIBLING_PRESENT:-no}}"
    fi
    printf 'inventory=%s examined=%s\n' "${INVENTORY:-0}" "${EXAMINED:-0}"
    if [ "${FLOOR_FAIL:-0}" -ne 0 ] && [ -n "${FLOOR_WHY:-}" ]; then
      printf 'inventory floor: %s\n' "$FLOOR_WHY"
    fi
    printf 'status=%s\n' "$status"
  )"
  n="$(grep -c '^VERDICT:' <<< "$content" || true)"
  if [ "$n" != 1 ]; then
    RECORD_WRITE_ERR="footer would write $n VERDICT lines (want 1)"
    return 1
  fi
  write_record replace rewrite <<<"$content"
}

append_row() {
  local extra="cand_calls=${LAST_CALLS:-0}|cand_ok=${LAST_OK:-0}|cand_fail=${LAST_FAIL:-0}|consumer_skips=${LAST_SKIPS:-0}|sibling_binary_present=${SIBLING_PRESENT:-no}"
  if [ -n "${LAST_PREREQ:-}" ]; then
    extra="$extra|prereq=$LAST_PREREQ"
  fi
  write_record append <<<"row|$1|$2|$3|$4|$5|$extra" || die_record "cannot append row to $RECORD"
}

# Last 60 lines of a non-PASS consumer's combined output, as log|<name>|<line>
# immediately after the row. CA-GUARD:log-tail is the append itself.
# A preflight UNRUNNABLE (no consumer output) still gets one log| line so
# every non-PASS row has at least one (#1214).
append_log_tail() {
  local name="$1" log="$2" line tailf reason
  if [ ! -f "$log" ] || [ ! -s "$log" ]; then
    reason="${LAST_PREREQ:+prereq:$LAST_PREREQ}"
    [ -n "$reason" ] || reason="${LAST_AMBIGUOUS:+ambiguous-workflow:$LAST_AMBIGUOUS}"
    [ -n "$reason" ] || reason="${LAST_VERDICT:-UNRUNNABLE}"
    write_record append <<<"log|$name|preflight: $reason" || die_record "cannot append preflight log to $RECORD"
    return 0
  fi
  # CA-GUARD:log-tail
  tailf="$WORK/tail.$name"
  tail -n 60 "$log" > "$tailf" 2>/dev/null || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    write_record append <<<"log|$name|$line" || die_record "cannot append log tail to $RECORD"
  done < "$tailf"
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
  local pid="$CA_INFLIGHT_PID"
  CA_INFLIGHT_PID=""
  # Reap the setsid group so a background child cannot keep the call-log
  # fd and write into the next row's slice.
  if [ -n "$pid" ]; then
    kill -TERM -- "-$pid" 2>/dev/null || true
    kill -KILL -- "-$pid" 2>/dev/null || true
  fi
}

LAST_VERDICT=""
LAST_RC=""
LAST_DUR=""

run_one() {
  local name="$1" pin="$2" cmd="$3"
  local repo="$ECO/$name" log start end cd_cmd eigs_exports prereq_tool
  LAST_VERDICT=""
  LAST_RC="-"
  LAST_DUR="0"
  LAST_CALLS=0
  LAST_OK=0
  LAST_FAIL=0
  LAST_SKIPS=0
  LAST_PREREQ=""

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

  # CA-GUARD:prereq
  if prereq_tool="$(missing_prereq "$name" "$cmd")"; then
    LAST_VERDICT=UNRUNNABLE
    LAST_PREREQ="$prereq_tool"
    LAST_RC="-"
    LAST_DUR="0"
    return
  fi

  # CA-GUARD:variant-mask
  local need v
  need="$(variants_of "$name") $cmd"
  # CA-GUARD:noglob-split
  local glob_off=0
  case "$-" in *f*) glob_off=1 ;; esac
  set -f
  for v in $need; do
    case "$v" in
      eigenscript) continue ;;
      eigenscript-full)
        if [ -z "${CAND_FULL_ABS:-}" ]; then
          [ -n "${SHIM:-}" ] && write_127_shim "$SHIM/$v" "$v"
          LAST_VERDICT=UNRUNNABLE
          LAST_PREREQ="variant:eigenscript-full"
          LAST_RC="-"
          LAST_DUR="0"
          [ "$glob_off" -eq 0 ] && set +f
          return
        fi
        ;;
      eigenscript-gfx)
        if [ -z "${CAND_GFX_ABS:-}" ]; then
          [ -n "${SHIM:-}" ] && write_127_shim "$SHIM/$v" "$v"
          LAST_VERDICT=UNRUNNABLE
          LAST_PREREQ="variant:eigenscript-gfx"
          LAST_RC="-"
          LAST_DUR="0"
          [ "$glob_off" -eq 0 ] && set +f
          return
        fi
        ;;
      eigenscript-*)
        [ -n "${SHIM:-}" ] && write_127_shim "$SHIM/$v" "$v"
        LAST_VERDICT=UNRUNNABLE
        LAST_PREREQ="variant:$v"
        LAST_RC="-"
        LAST_DUR="0"
        [ "$glob_off" -eq 0 ] && set +f
        return
        ;;
    esac
  done
  [ "$glob_off" -eq 0 ] && set +f
  # CA-GUARD:end-variant-mask

  log="$WORK/logs/$name.log"
  mkdir -p "$WORK/logs"
  # Arm this row's slice of the private log (new inode, so a straggler
  # holding the previous fd cannot append here). The harness
  # --version/--api probes ran before any row log existed and used
  # CAND_ABS, not the shim.
  if [ -n "${CALL_LOG:-}" ]; then
    rm -f "$CALL_LOG"
    : > "$CALL_LOG"
  fi

  eigs_exports=""
  # CA-GUARD:eigs-dir
  if [ -n "${CAND_OVERLAY:-}" ]; then
    eigs_exports="$(printf 'export EIGS_DIR=%q\nexport EIGENSCRIPT_DIR=%q\n' "$CAND_OVERLAY" "$CAND_OVERLAY")"
  fi
  # CA-GUARD:eigenscript-bin
  if true; then
    if [ -n "$eigs_exports" ]; then
      eigs_exports="${eigs_exports}"$'\n'
    fi
    eigs_exports="${eigs_exports}$(printf 'export EIGENSCRIPT_BIN=%q\n' "$SHIM/eigenscript")"
    if [ "${CAND_HAS_GFX:-0}" = 1 ]; then
      eigs_exports="${eigs_exports}"$'\n'"$(printf 'export EIGENSCRIPT_GFX=%q\n' "$SHIM/eigenscript")"
    fi
  fi
  # CA-GUARD:private-log-export
  true
  # CA-GUARD:strip-ca-env
  strip_ca='for _ca_k in $(env | awk -F= '\''$1 ~ /^CA_/ {print $1}'\''); do unset "$_ca_k"; done'

  cd_cmd="$(printf 'export PATH=%q:"$PATH"\nexport EIGS=eigenscript\nexport EIGENSCRIPT=eigenscript\n%s\n%s\ncd %q || exit 125\n%s\n' "$SHIM" "$eigs_exports" "$strip_ca" "$repo" "$cmd")"

  start="$(date +%s)"
  # CA-GUARD:block-pipefail
  run_bounded "$log" bash -e -o pipefail -c "$cd_cmd"
  end="$(date +%s)"
  LAST_DUR=$((end - start))
  if [ "$LAST_DUR" -lt 0 ]; then LAST_DUR=0; fi

  LAST_CALLS="$(grep -c '^call|' "${CALL_LOG:-/dev/null}" 2>/dev/null || true)"
  LAST_CALLS="${LAST_CALLS:-0}"
  LAST_OK="$(grep -c '^call|rc=0|' "${CALL_LOG:-/dev/null}" 2>/dev/null || true)"
  LAST_OK="${LAST_OK:-0}"
  LAST_FAIL=$((LAST_CALLS - LAST_OK))
  if [ "$LAST_FAIL" -lt 0 ]; then LAST_FAIL=0; fi
  LAST_SKIPS="$(grep -c '^SKIP' "$log" 2>/dev/null || true)"
  LAST_SKIPS="${LAST_SKIPS:-0}"
  # CA-GUARD:probe-not-attributed
  # The harness --version/--api/bind probes ran against CAND_ABS (not the
  # shim) before this log was armed; the per-row recreate drops them.

  case "$LAST_RC" in
    0)   LAST_VERDICT=PASS ;;
    124) LAST_VERDICT=HANG ;;
    137) LAST_VERDICT=KILLED ;;
    125) LAST_VERDICT=UNRUNNABLE ;;
    *)   LAST_VERDICT=FAIL ;;
  esac
  # CA-GUARD:cand-calls
  # A PASS that never reached the candidate is UNEXERCISED (mechanical-gates
  # §113: every arm must prove it RAN). HANG/KILLED/UNRUNNABLE/FAIL keep
  # their names -- cand_calls=0 cannot be PASS.
  if [ "$LAST_VERDICT" = PASS ] && [ "$LAST_CALLS" -eq 0 ]; then
    LAST_VERDICT=UNEXERCISED
  fi
  # CA-GUARD:swallowed
  # Command exited 0 AND no nontrivial candidate invocation succeeded:
  # the candidate never once worked and the consumer still reported success.
  # A nonzero candidate rc is not by itself a failure (lint/fail-soft).
  if [ "$LAST_VERDICT" = PASS ] && [ "${LAST_OK:-0}" -eq 0 ] && [ "${LAST_FAIL:-0}" -gt 0 ]; then
    LAST_VERDICT=SWALLOWED
  fi
  if [ "$LAST_VERDICT" = PASS ] && [ "${LAST_SKIPS:-0}" -gt 0 ]; then
    LAST_VERDICT="PASS|skips=$LAST_SKIPS"
  fi
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
  elif [ "${FLOOR_FAIL:-0}" -ne 0 ]; then
    final=FAIL
    RUN_RC=1
    if [ -n "${FLOOR_WHY:-}" ]; then
      say "inventory floor: ${FLOOR_WHY}"
    fi
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
  emit_stdout_verdict "$final"
  RECORD_FINISHED=1
  exit "$RUN_RC"
}

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'unavailable'
  fi
}

write_counting_shim() {
  local dest="$1" target="$2"
  {
    printf '%s\n' '#!/bin/sh'
    printf 'target=%s\n' "$(printf '%q' "$target")"
    printf 'log=%s\n' "$(printf '%q' "$CALL_LOG")"
    printf '%s\n' \
      'log="$log"' \
      'kind=probe' \
      'for _a in "$@"; do' \
      '  case "$_a" in' \
      '    --version|--api|--help|-h|-v) ;;' \
      '    -*) ;;' \
      '    *) kind=call ;;' \
      '  esac' \
      'done' \
      '"$target" "$@"' \
      'rc=$?' \
      'printf "%s|rc=%s|%s\n" "$kind" "$rc" "$*" >> "$log"' \
      'exit "$rc"'
  } > "$dest"
  chmod +x "$dest"
}

write_127_shim() {
  local dest="$1" name="$2"
  printf '%s\n' '#!/bin/sh' \
    "echo \"consumer_acceptance: no candidate for $name\" >&2" \
    'exit 127' > "$dest"
  chmod +x "$dest"
}

run_mode() {
  # CA-GUARD:not-crash
  local cand="" arg
  CAND_FULL=""
  CAND_GFX=""
  CAND_FULL_ABS=""
  CAND_GFX_ABS=""
  CAND_SHA=""
  CAND_FULL_VER=""
  CAND_FULL_SHA=""
  CAND_GFX_VER=""
  CAND_GFX_SHA=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --full)
        [ $# -ge 2 ] || { say "usage: $0 run <tree-or-binary> [--full <binary>] [--gfx <binary>]"; exit 2; }
        CAND_FULL="$2"; shift 2 ;;
      --gfx)
        [ $# -ge 2 ] || { say "usage: $0 run <tree-or-binary> [--full <binary>] [--gfx <binary>]"; exit 2; }
        CAND_GFX="$2"; shift 2 ;;
      -*)
        say "usage: $0 run <tree-or-binary> [--full <binary>] [--gfx <binary>]"
        exit 2 ;;
      *)
        if [ -z "$cand" ]; then cand="$1"; shift
        else
          say "usage: $0 run <tree-or-binary> [--full <binary>] [--gfx <binary>]"
          exit 2
        fi ;;
    esac
  done
  resolve_eco
  probe_timeout
  # Unset → default 1800. Empty / 0 / 00 / non-integer → exit 2 below.
  if [ "${CA_TIMEOUT+set}" = set ]; then
    BUDGET="$CA_TIMEOUT"
  else
    BUDGET=1800
  fi
  KILL_AFTER="${CA_KILL_AFTER:-10}"

  # CA-GUARD:usage-before-record
  # Static argument validation happens BEFORE any record path is touched.
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

  if [ -z "$TMO_BIN" ]; then
    say "consumer_acceptance: no timeout(1)/gtimeout(1) on PATH -- refusing to run unbounded"
    exit 2
  fi
  if [ -z "$cand" ]; then
    say "usage: $0 run <tree-or-binary> [--full <binary>] [--gfx <binary>]"
    exit 2
  fi
  if [ ! -f "$cand" ] || [ ! -x "$cand" ]; then
    say "consumer_acceptance: candidate is not an executable file: $cand"
    exit 2
  fi
  CAND_ABS="$(abs_path "$cand")" || { say "consumer_acceptance: cannot resolve candidate path: $cand"; exit 2; }
  if [ -n "$CAND_FULL" ]; then
    if [ ! -f "$CAND_FULL" ] || [ ! -x "$CAND_FULL" ]; then
      say "consumer_acceptance: --full is not an executable file: $CAND_FULL"
      exit 2
    fi
    CAND_FULL_ABS="$(abs_path "$CAND_FULL")" || { say "consumer_acceptance: cannot resolve --full path: $CAND_FULL"; exit 2; }
  fi
  if [ -n "$CAND_GFX" ]; then
    if [ ! -f "$CAND_GFX" ] || [ ! -x "$CAND_GFX" ]; then
      say "consumer_acceptance: --gfx is not an executable file: $CAND_GFX"
      exit 2
    fi
    CAND_GFX_ABS="$(abs_path "$CAND_GFX")" || { say "consumer_acceptance: cannot resolve --gfx path: $CAND_GFX"; exit 2; }
  fi
  # CA-GUARD:end-usage-before-record

  RUN_ID="$(date +%s).$$.${RANDOM:-0}"
  STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)"

  if [ -n "${CA_RECORD:-}" ]; then
    RECORD="$CA_RECORD"
  else
    RECORD="$(mktemp "${TMPDIR:-/tmp}/ca-record.XXXXXX")"
    # mktemp creates an empty file; do not stash it as .prev on a fresh run.
    rm -f "$RECORD"
  fi

  # First actions -- before the inventory scan, before the shim, before
  # the candidate. A previous PASS must not outlive this point. The lock
  # is taken BEFORE invalidate so a second invocation refuses without
  # touching the live record.
  # CA-GUARD:traps-before-scan
  install_run_traps
  # CA-GUARD:record-lock
  if ! acquire_record_lock; then
    RECORD_FINISHED=1
    RUN_RC=2
    exit 2
  fi
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/ca-run.XXXXXX")"
  # CA-GUARD:invalidate-fail-closed
  invalidate_previous_record || die_record "cannot invalidate previous record at $RECORD"
  write_record_header || die_record "cannot initialise record at $RECORD"
  HEADER_WRITTEN=1
  # CA-GUARD:end-traps-before-scan

  SHIM="$WORK/bin"
  mkdir -p "$SHIM"
  # Private call log: a directory the consumer is never told about (not
  # the shim dir, not $EIGS_DIR, not their parents). Path baked into the
  # shim. Residual: any same-uid consumer that finds the shim script and
  # reads it can still recover the path.
  PRIV="$(mktemp -d "${TMPDIR:-/tmp}/ca-priv.XXXXXX")"
  local _hid
  _hid="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [ -n "$_hid" ] || _hid="c${RANDOM}${RANDOM}"
  mkdir -p "$PRIV/.$_hid"
  CALL_LOG="$PRIV/.$_hid/log"
  : > "$CALL_LOG"
  # Counting wrapper, not a symlink: records argv+rc then runs the
  # candidate (cannot exec -- we need the rc). Probe argv does not count.
  {
    printf '%s\n' '#!/bin/sh'
    printf 'target=%s\n' "$(printf '%q' "$CAND_ABS")"
    printf 'log=%s\n' "$(printf '%q' "$CALL_LOG")"
    printf '%s\n' \
      '# CA-GUARD:private-log' \
      'log="$log"' \
      '# CA-GUARD:nontrivial-calls' \
      'kind=probe' \
      'for _a in "$@"; do' \
      '  case "$_a" in' \
      '    --version|--api|--help|-h|-v) ;;' \
      '    -*) ;;' \
      '    *) kind=call ;;' \
      '  esac' \
      'done' \
      '"$target" "$@"' \
      'rc=$?' \
      'printf "%s|rc=%s|%s\n" "$kind" "$rc" "$*" >> "$log"' \
      'exit "$rc"'
  } > "$SHIM/eigenscript"
  chmod +x "$SHIM/eigenscript"
  RESOLVED="$SHIM/eigenscript"
  # CA-GUARD:variant-mask
  if [ -n "${CAND_FULL_ABS:-}" ]; then
    write_counting_shim "$SHIM/eigenscript-full" "$CAND_FULL_ABS"
  else
    write_127_shim "$SHIM/eigenscript-full" eigenscript-full
  fi
  if [ -n "${CAND_GFX_ABS:-}" ]; then
    write_counting_shim "$SHIM/eigenscript-gfx" "$CAND_GFX_ABS"
  else
    write_127_shim "$SHIM/eigenscript-gfx" eigenscript-gfx
  fi
  # CA-GUARD:end-variant-mask
  derive_candidate_tree "$CAND_ABS" || true
  if [ -z "${CAND_TREE:-}" ] && [ -e "$ECO/EigenScript" ]; then
    say "consumer_acceptance: refusing a bare candidate ($CAND_ABS) while sibling tree $ECO/EigenScript exists; pass a tree candidate (.../src/eigenscript) so EIGS_DIR is an overlay of the candidate"
    RUN_RC=2
    exit 2
  fi
  CAND_OVERLAY=""
  if [ -n "${CAND_TREE:-}" ]; then
    build_candidate_overlay "$CAND_TREE" "$WORK/cand_tree" || true
  fi
  SIBLING_BEFORE="$(sibling_is_present)"
  SIBLING_PRESENT="$SIBLING_BEFORE"
  SIBLING_AFTER="$SIBLING_BEFORE"

  # CA-GUARD:scan-inventory
  scan_inventory
  # CA-GUARD:end-scan-inventory

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
  if [ -n "${CAND_TREE:-}" ]; then
    say "candidate_tree: $CAND_TREE"
  else
    say "candidate_tree: (bare binary, no src/eigenscript tree)"
  fi
  say "eigenscript_resolved: $RESOLVED"
  say "sibling_binary_present: $SIBLING_BEFORE"
  if [ "$SIBLING_BEFORE" = yes ]; then
    say "note: \$ECO/EigenScript/src/eigenscript exists and differs from the candidate; consumers with hard-coded sibling paths (DMG#73) may have used it"
  fi
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
  CAND_SHA="$(file_sha256 "$CAND_ABS")"
  say "candidate_version: $CAND_VER"
  say "candidate_sha256: $CAND_SHA"
  if [ -n "${CAND_FULL_ABS:-}" ]; then
    run_bounded "$WORK/full_ver.log" "$CAND_FULL_ABS" --version
    CAND_FULL_VER="$(head -1 "$WORK/full_ver.log" 2>/dev/null || true)"
    CAND_FULL_SHA="$(file_sha256 "$CAND_FULL_ABS")"
    say "candidate_full: $CAND_FULL_ABS version=${CAND_FULL_VER:-} sha256=$CAND_FULL_SHA"
  fi
  if [ -n "${CAND_GFX_ABS:-}" ]; then
    run_bounded "$WORK/gfx_ver.log" "$CAND_GFX_ABS" --version
    CAND_GFX_VER="$(head -1 "$WORK/gfx_ver.log" 2>/dev/null || true)"
    CAND_GFX_SHA="$(file_sha256 "$CAND_GFX_ABS")"
    say "candidate_gfx_bin: $CAND_GFX_ABS version=${CAND_GFX_VER:-} sha256=$CAND_GFX_SHA"
  fi

  # Capability probe: --api --json is the language-surface index. gfx_open
  # listed there is necessary but not sufficient (a real binary always
  # lists the gfx group even when built headless); a bind probe confirms
  # the name is actually defined. Stubs that omit gfx_open skip the bind.
  CAND_HAS_GFX=0
  CAND_GFX_RC=""
  local api_log gfx_bind_log gfx_bind_src
  api_log="$WORK/api.log"
  run_bounded "$api_log" "$CAND_ABS" --api --json
  if [ ! -s "$api_log" ]; then
    run_bounded "$api_log" "$CAND_ABS" --api
  fi
  if grep -q 'gfx_open' "$api_log" 2>/dev/null; then
    gfx_bind_src="$WORK/gfx_bind.eigs"
    gfx_bind_log="$WORK/gfx_bind.log"
    printf 'print of gfx_open\n' > "$gfx_bind_src"
    run_bounded "$gfx_bind_log" "$CAND_ABS" "$gfx_bind_src"
    CAND_GFX_RC="$LAST_RC"
    # A defined gfx_open prints <fn gfx_open> (named native) or <builtin>
    # (older unnamed native). rc 0 with neither is not gfx. Any nonzero
    # is unknown (segfault, undefined variable, …).
    if [ "$LAST_RC" -eq 0 ] \
       && grep -qE '<fn gfx_open>|<builtin>' "$gfx_bind_log" 2>/dev/null \
       && ! grep -q "undefined variable" "$gfx_bind_log" 2>/dev/null; then
      CAND_HAS_GFX=1
    elif [ "$LAST_RC" -ne 0 ]; then
      CAND_HAS_GFX=unknown
    else
      CAND_HAS_GFX=0
    fi
  fi
  if [ -n "${CAND_GFX_ABS:-}" ]; then
    CAND_HAS_GFX=1
  fi
  say "candidate_gfx: $CAND_HAS_GFX"

  local i name pin cmd verdict STOP_AFTER kind
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
    if [ "$i" -eq 0 ] && fixture_fault && [ "${CA_FAULT:-}" = foreign_record ]; then
      printf '%s\n' '# foreign' 'run_id=FOREIGN_RUN' 'status=INCOMPLETE' 'inventory=PENDING' 'examined=PENDING' 'VERDICT: INCOMPLETE' > "$RECORD"
    fi
    name="${GATE_NAMES[$i]}"
    pin="${GATE_PINS[$i]}"
    cmd="${GATE_CMDS[$i]}"
    kind="${GATE_KINDS[$i]}"
    LAST_AMBIGUOUS=""
    if [ "$kind" = ambiguous ]; then
      LAST_VERDICT=UNRUNNABLE
      LAST_RC="-"; LAST_DUR="0"
      LAST_CALLS=0; LAST_OK=0; LAST_FAIL=0; LAST_SKIPS=0
      LAST_PREREQ=""
      LAST_AMBIGUOUS="${GATE_WFS[$i]}"
    else
      run_one "$name" "$pin" "$cmd"
    fi
    verdict="$LAST_VERDICT"
    append_row "$name" "$pin" "$verdict" "$LAST_RC" "$LAST_DUR"
    case "$verdict" in
      PASS|PASS\|*) ;;
      *)
        append_log_tail "$name" "$WORK/logs/$name.log"
        ;;
    esac
    EXAMINED=$((EXAMINED + 1))
    if [ -n "${LAST_AMBIGUOUS:-}" ]; then
      say "  UNRUNNABLE|ambiguous-workflow:${LAST_AMBIGUOUS}  $name  pin=$pin rc=$LAST_RC ${LAST_DUR}s cand_calls=${LAST_CALLS:-0} cand_ok=${LAST_OK:-0} cand_fail=${LAST_FAIL:-0} consumer_skips=${LAST_SKIPS:-0} sibling_binary_present=${SIBLING_PRESENT:-no}"
    elif [ -n "${LAST_PREREQ:-}" ]; then
      say "  UNRUNNABLE|prereq:${LAST_PREREQ}  $name  pin=$pin rc=$LAST_RC ${LAST_DUR}s cand_calls=${LAST_CALLS:-0} cand_ok=${LAST_OK:-0} cand_fail=${LAST_FAIL:-0} consumer_skips=${LAST_SKIPS:-0} sibling_binary_present=${SIBLING_PRESENT:-no}"
    else
      say "  $verdict  $name  pin=$pin rc=$LAST_RC ${LAST_DUR}s cand_calls=${LAST_CALLS:-0} cand_ok=${LAST_OK:-0} cand_fail=${LAST_FAIL:-0} consumer_skips=${LAST_SKIPS:-0} sibling_binary_present=${SIBLING_PRESENT:-no}"
    fi
    if [ "$verdict" != PASS ]; then
      ANY_BAD=1
    fi
    if [ "$STOP_AFTER" -gt 0 ] && [ "$EXAMINED" -ge "$STOP_AFTER" ]; then
      break
    fi
    i=$((i + 1))
  done

  SIBLING_AFTER="$(sibling_is_present)"
  SIBLING_PRESENT="$SIBLING_AFTER"
  if [ "$SIBLING_AFTER" != "$SIBLING_BEFORE" ]; then
    say "sibling_binary_present_after: $SIBLING_AFTER"
    say "sibling_binary_present_changed: ${SIBLING_BEFORE}→${SIBLING_AFTER}"
  else
    say "sibling_binary_present_after: $SIBLING_AFTER"
  fi

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
  printf '%s\n' "#!/bin/sh" \
    "if [ \"\${1:-}\" = --version ]; then echo 'eigenscript stub'; exit 0; fi" \
    "if [ \"\${1:-}\" = --api ]; then echo '{\"builtins\":[]}'; exit 0; fi" \
    "exit $rc" > "$path"
  chmod +x "$path"
}

mk_stub_hang_version() {
  local path="$1"
  printf '%s\n' "#!/bin/sh" "if [ \"\${1:-}\" = --version ]; then sleep 30; echo hang-version; exit 0; fi" "exit 0" > "$path"
  chmod +x "$path"
}

# --api lists gfx_open so the harness bind probe (a positional .eigs) runs.
mk_stub_gfx() {
  local path="$1"
  printf '%s\n' '#!/bin/sh' \
    'if [ "${1:-}" = --version ]; then echo "eigenscript stub"; exit 0; fi' \
    'if [ "${1:-}" = --api ]; then echo "{\"builtins\":[\"gfx_open\"]}"; exit 0; fi' \
    'exit 0' > "$path"
  chmod +x "$path"
}

plant_line() {
  local name="$1" st="$2" detail="${3:-}"
  ST_PLANTS=$((${ST_PLANTS:-0} + 1))
  if [ "$st" -eq 0 ]; then
    say "plant $name: FIRES${detail:+ -- $detail}"
  else
    say "plant $name: SILENT${detail:+ -- $detail}"
    ST_FAIL=1
  fi
}

exact_verdict() {
  local src="$1" v="$2" n
  n="$(grep -c '^VERDICT:' <<< "$src" || true)"
  [ "$n" = 1 ] && grep -qx "VERDICT: $v" <<< "$src"
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
  ST_RUNS=$((${ST_RUNS:-0} + 1))
  if grep -q 'unbound variable' <<< "${1:-}"; then
    ST_UNBOUND=$((${ST_UNBOUND:-0} + 1))
  fi
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
  if grep -q '^VERDICT: PASS' <<< "$out"; then
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
  if [ "$rc" -ne 0 ] && grep -q "GAP    zz-planted-consumer" <<< "$out" \
     && grep -q '^VERDICT: FAIL' <<< "$out"; then
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
     && grep -q 'VERDICT: PASS' <<< "$out" \
     && ! grep -qx 'VERDICT: PASS' <<< "$out"; then
    return 0
  fi
  return 1
}

# D / D2: SIGTERM/SIGHUP mid-wave. FIRE: exit 2, record INCOMPLETE, and
# exactly one `VERDICT: INCOMPLETE` line on stdout (the record header
# already says INCOMPLETE, so stdout is what finish_incomplete does).
plant_interruption() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local sig="${5:-TERM}"
  local pid waited rc t0 t1 elapsed n_out outf
  outf="${rec}.stdout"
  rm -f "$outf"
  CA_ECO="$eco" CA_TIMEOUT=20 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" >"$outf" 2>&1 &
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
  kill -"$sig" "$pid" 2>/dev/null || true
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
  n_out="$(grep -c '^VERDICT: INCOMPLETE$' "$outf" 2>/dev/null || true)"
  LAST_PLANT_DETAIL="rc=$rc elapsed=${elapsed}s n_out=$n_out rec=$(grep '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$(cat "$outf" 2>/dev/null || true)" "$rec" "$rc"
  if [ "$rc" -eq 2 ] \
     && [ "$n_out" = 1 ] \
     && grep -q '^VERDICT: INCOMPLETE$' "$rec" \
     && grep -q 'status=INCOMPLETE' "$rec" \
     && [ "$elapsed" -le 5 ]; then
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
#
# uid 0 writes THROUGH a chmod a-w directory, so as root the fault cannot be
# planted at all (measured: PR #1224's `gate self-tests` job runs as root in
# the devcontainer and this row read intact=SILENT mutant=SILENT FAIL). As
# root the plant drops to an unprivileged user (runuser/setpriv + nobody) and
# opens the path so that user can reach the fixture. When no such user or
# tool exists, or a positive precondition PROBE under that user fails, the
# plant returns 3 = SKIP and the caller names it; the self-test's final line
# reports skipped=N so the count is never a silent OK.
# CA_FAULT=pretend_root (fixture-gated) takes the same decision branch on a
# non-root box, where no drop tool applies, so the SKIP path is exercised.
plant_stale_unwritable() {
  local sh="$1" eco="$2" stub="$3" rec_hint="$4"
  local dir rec out rc drop="" as_root=0 why="" drop_tmp="" a
  [ "$(id -u)" = 0 ] && as_root=1
  # Gated on the FIXTURE's own marker (the self-test's ECO is the repo, not
  # a fixture, so fixture_fault would not see it).
  if [ -f "${eco:-}/.ca_fixture" ] && [ "${CA_FAULT:-}" = pretend_root ]; then
    as_root=1
  fi
  if [ "$as_root" -eq 1 ]; then
    if [ "$(id -u)" = 0 ] && getent passwd nobody >/dev/null 2>&1; then
      if command -v runuser >/dev/null 2>&1; then
        drop="runuser -u nobody --"
      elif command -v setpriv >/dev/null 2>&1; then
        drop="setpriv --reuid=nobody --regid=nogroup --clear-groups"
      fi
    fi
    if [ -z "$drop" ]; then
      why="no runuser/setpriv with a nobody user"
      LAST_PLANT_DETAIL="SKIP (root: $why)"
      note_plant "plant stale-unwritable: SKIP (root: $why)" "" 0
      return 3
    fi
  fi
  dir="${rec_hint}.rodir"
  mkdir -p "$dir"
  rec="$dir/record"
  printf '%s\n' 'run_id=OLD_RUN' 'status=COMPLETE' 'inventory=1 examined=1' 'VERDICT: PASS' > "$rec"
  if [ -n "$drop" ]; then
    # The unprivileged user must traverse to $dir, read the fixture and the
    # script, and own a writable TMPDIR. Open the path, then PROBE it.
    a="$dir"
    while [ "$a" != "/" ] && [ -n "$a" ]; do
      chmod a+rX "$a" 2>/dev/null || true
      a="$(dirname "$a")"
    done
    chmod -R a+rX "$eco" 2>/dev/null || true
    chmod a+rx "$sh" "$stub" 2>/dev/null || true
    chmod a+r "$rec" 2>/dev/null || true
    drop_tmp="${rec_hint}.droptmp"
    mkdir -p "$drop_tmp" && chmod 1777 "$drop_tmp" 2>/dev/null || true
    if ! $drop sh -c 'test -r "$1" && test -x "$2" && test -d "$3" && : > "$3/probe"' \
         _ "$rec" "$sh" "$drop_tmp" >/dev/null 2>&1; then
      why="unprivileged probe failed (cannot reach the fixture as nobody)"
      LAST_PLANT_DETAIL="SKIP (root: $why)"
      note_plant "plant stale-unwritable: SKIP (root: $why)" "" 0
      return 3
    fi
  fi
  chmod a-w "$dir"
  if [ -n "$drop" ]; then
    out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" TMPDIR="$drop_tmp" \
      $drop "$sh" run "$stub" 2>&1)"
    rc=$?
  else
    out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
    rc=$?
  fi
  chmod u+w "$dir"
  LAST_PLANT_DETAIL="rc=$rc drop=${drop:-none} rec=$(grep '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] && { [ ! -f "$rec" ] || ! grep -q '^VERDICT: PASS$' "$rec"; }; then
    return 0
  fi
  return 1
}

# J / Q: signal during finalization (PATH shim for mv). FIRE: exactly one
# VERDICT line in the record, rc 0, and exactly one stdout VERDICT: PASS.
plant_footer_signal() {
  local sh="$1" eco="$2" stub="$3" rec="$4" shim="${5:-}"
  local out rc n env_path n_out
  env_path="$PATH"
  [ -n "$shim" ] && env_path="$shim:$PATH"
  out="$(PATH="$env_path" CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  n=0
  [ -f "$rec" ] && n="$(grep -c '^VERDICT:' "$rec" || true)"
  n_out="$(grep -c '^VERDICT:' <<< "$out" || true)"
  LAST_PLANT_DETAIL="rc=$rc n=$n n_out=$n_out rec=$(grep '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$n" = 1 ] && [ "$rc" -eq 0 ] && [ "$n_out" = 1 ] && exact_verdict "$out" PASS; then
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
  if [ "$rc" -eq 2 ] && grep -q 'positive integer' <<< "$out"; then
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

# N: second invocation on the same CA_RECORD is refused. FIRE: run 2 exits 2
# with the busy message; run 1 finishes PASS with exactly one VERDICT.
plant_record_busy() {
  local sh="$1" eco1="$2" eco2="$3" stub_ok="$4" stub_bad="$5" rec="$6"
  local log1 pid1 rc1 rc2 out2 waited n
  log1="${rec}.log1"
  rm -f "$rec" "$log1"
  rm -rf "${rec}.lock.d"
  CA_ECO="$eco1" CA_TIMEOUT=10 CA_KILL_AFTER=1 CA_RECORD="$rec" \
    "$sh" run "$stub_ok" >"$log1" 2>&1 &
  pid1=$!
  waited=0
  while [ "$waited" -lt 50 ]; do
    if [ -d "${rec}.lock.d" ]; then
      break
    fi
    # Mutant with no lock: start run 2 as soon as run 1 has a header,
    # so the two actually interleave rather than waiting out the sleep.
    if [ -f "$rec" ] && grep -q '^run_id=' "$rec" 2>/dev/null; then
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  # Run 2 uses the same passing stub: without the lock it completes PASS
  # (the interleaving the plant exists to stop). A failing stub would
  # make the gutted mutant BROKEN-MUTANT rather than SILENT.
  out2="$(CA_ECO="$eco2" CA_TIMEOUT=10 CA_KILL_AFTER=1 CA_RECORD="$rec" \
    "$sh" run "$stub_ok" 2>&1)"
  rc2=$?
  wait "$pid1"
  rc1=$?
  n=0
  [ -f "$rec" ] && n="$(grep -c '^VERDICT:' "$rec" || true)"
  LAST_PLANT_DETAIL="rc1=$rc1 rc2=$rc2 n=$n busy=$(grep -c 'record busy' <<< "$out2" || true)"
  note_plant "$out2" "$rec" "$rc2"
  if [ "$rc2" -eq 2 ] \
     && grep -q 'record busy (held by run' <<< "$out2" \
     && [ "$rc1" -eq 0 ] \
     && [ "$n" = 1 ] \
     && exact_verdict_file "$rec" PASS \
     && ! grep -q '|FAIL|' "$rec"; then
    return 0
  fi
  return 1
}

# O: mid-run foreign file is refused. FIRE: FAIL by name (record not ours),
# foreign file clobbered in place, exit 1.
plant_foreign_record() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_FAULT=foreign_record CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep -E 'run_id=|VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'record not ours' <<< "$out" \
     && [ -f "$rec" ] \
     && ! grep -q '^VERDICT: PASS$' "$rec" \
     && ! grep -q '^run_id=FOREIGN_RUN$' "$rec" \
     && grep -q '^VERDICT: INCOMPLETE$' "$rec"; then
    return 0
  fi
  return 1
}

# P: FAIL footer write fails; finish_incomplete still lands INCOMPLETE.
plant_fail_footer() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_FAULT=fail_footer CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q '^VERDICT: INCOMPLETE$' "$rec"; then
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

# R: command `true` never calls the candidate. FIRE: UNEXERCISED, FAIL.
plant_unexercised() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|r_true|v0.43.0|UNEXERCISED|' "$rec" \
     && grep -q 'cand_calls=0' "$rec" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# S: tree consumer invokes "$EIGS_DIR/src/eigenscript". FIRE: PASS cand_calls=1
# and candidate_tree= the dir containing that src/eigenscript. stub is the
# tree-shaped candidate (.../src/eigenscript).
plant_tree_consumer() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc tree
  tree="$(cd "$(dirname "$stub")/.." && pwd)" || return 1
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep -E 'candidate_tree=|^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 0 ] \
     && exact_verdict_file "$rec" PASS \
     && grep -q "^candidate_tree=$tree$" "$rec" \
     && grep -q 'row|tree_user|v0.43.0|PASS|' "$rec" \
     && grep -q 'cand_calls=1' "$rec"; then
    return 0
  fi
  return 1
}

# T: DECLARED command names a file that does not exist. FIRE: plan GAP + FAIL.
plant_declared_missing() {
  local sh="$1" eco="$2"
  local out rc
  out="$(CA_ECO="$eco" "$sh" plan 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc"
  note_plant "$out" "" "$rc"
  if [ "$rc" -ne 0 ] \
     && grep -q "declared command's file does not exist" <<< "$out" \
     && grep -q '^VERDICT: FAIL' <<< "$out"; then
    return 0
  fi
  return 1
}

# U: PREREQS names a tool that is not on PATH. FIRE: UNRUNNABLE|prereq:<tool>.
plant_prereq_missing() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|u_prereq|v0.43.0|UNRUNNABLE|' "$rec" \
     && grep -q 'prereq=nonexistent-tool' "$rec" \
     && grep -q 'UNRUNNABLE|prereq:nonexistent-tool' <<< "$out" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# V: consumer writes call| lines into CA_CAND_COUNT_FILE. FIRE: UNEXERCISED
# (the log is not that env var).
plant_forged_counter() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|v_forge|v0.43.0|UNEXERCISED|' "$rec" \
     && grep -q 'cand_calls=0' "$rec" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# W: eigenscript --version only. FIRE: UNEXERCISED (probe, not a call).
plant_version_only() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|w_ver|v0.43.0|UNEXERCISED|' "$rec" \
     && grep -q 'cand_calls=0' "$rec" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# X: eigenscript bad.eigs || true. FIRE: SWALLOWED (cand_ok=0 cand_fail>0).
plant_swallowed() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|x_swall|v0.43.0|SWALLOWED|' "$rec" \
     && grep -q 'cand_ok=0' "$rec" \
     && grep -q 'cand_fail=1' "$rec" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# Y: overlay write does not touch the candidate lib/; realpath stays in
# the overlay and is counted. stub is the tree-shaped candidate.
plant_overlay_write() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc tree before after
  tree="$(cd "$(dirname "$stub")/.." && pwd)" || return 1
  before="$(cksum "$tree/lib/marker" 2>/dev/null || echo missing)"
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  after="$(cksum "$tree/lib/marker" 2>/dev/null || echo missing)"
  LAST_PLANT_DETAIL="rc=$rc before=$before after=$after rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 0 ] \
     && [ "$before" = "$after" ] \
     && grep -q 'row|y_ov|v0.43.0|PASS|' "$rec" \
     && grep -q 'cand_calls=1' "$rec" \
     && exact_verdict_file "$rec" PASS; then
    return 0
  fi
  return 1
}

# Z: consumer runs nothing. FIRE: cand_calls=0 (pre-run probe not attributed).
plant_probe_not_attributed() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|z_idle|v0.43.0|UNEXERCISED|' "$rec" \
     && grep -q 'cand_calls=0' "$rec" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# AA: script prefers sibling over PATH but honours EIGENSCRIPT_BIN first.
# FIRE: PASS cand_calls=1 and the sibling log is empty.
plant_bin_routing() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc slog
  slog="$eco/../aa-sibling.log"
  rm -f "$slog"
  : > "$slog"
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc slog=$(wc -c < "$slog" 2>/dev/null || echo 0) rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 0 ] \
     && exact_verdict_file "$rec" PASS \
     && grep -q 'row|aa_route|v0.43.0|PASS|' "$rec" \
     && grep -q 'cand_calls=1' "$rec" \
     && [ ! -s "$slog" ]; then
    return 0
  fi
  return 1
}

# AB: gfx in PREREQS, candidate --api omits gfx_open. FIRE: UNRUNNABLE|prereq:gfx-build.
plant_gfx_prereq() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|ab_gfx|v0.43.0|UNRUNNABLE|' "$rec" \
     && grep -q 'prereq=gfx-build' "$rec" \
     && grep -q 'UNRUNNABLE|prereq:gfx-build' <<< "$out" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# AC: consumer swaps the record for a symlink to a victim. FIRE: victim
# keeps its bytes (clobber unlinks, never truncates through the link).
# The swap command bakes THIS rec path (CA_RECORD is unset in the consumer).
plant_clobber_symlink() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc victim
  victim="${rec}.victim"
  printf 'VICTIM DATA -- 1234567890\n' > "$victim"
  mk_consumer_block "$eco" ac_swap \
    "eigenscript work.eigs" \
    "rm -f $rec" \
    "ln -s $victim $rec"
  LAST_PLANT_DETAIL=""
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc victim=$(wc -c < "$victim" 2>/dev/null || echo missing) rec=$(grep '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ -f "$victim" ] \
     && grep -q 'VICTIM DATA -- 1234567890' "$victim"; then
    return 0
  fi
  return 1
}

# Straggler from row N must not land in row N+1. FIRE: b_never_calls UNEXERCISED.
plant_straggler() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=8 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if grep -q 'row|b_never_calls|v0.43.0|UNEXERCISED|' "$rec" \
     && grep -q 'cand_calls=0' "$rec"; then
    return 0
  fi
  return 1
}

# Export-block join: EIGENSCRIPT_DIR equals EIGS_DIR and ends in cand_tree.
plant_exports_join() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 0 ] \
     && grep -q 'row|exp_join|v0.43.0|PASS|' "$rec" \
     && exact_verdict_file "$rec" PASS; then
    return 0
  fi
  return 1
}

# Find every regular file under the shim dir's parent and $EIGS_DIR; forging
# them must leave the row UNEXERCISED.
plant_private_find() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|priv_find|v0.43.0|UNEXERCISED|' "$rec" \
     && grep -q 'cand_calls=0' "$rec" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# Overlay symlink: write through $EIGS_DIR/lib/link must not change the
# outside file. stub is the tree-shaped candidate.
plant_overlay_symlink() {
  local sh="$1" eco="$2" stub="$3" rec="$4" outside="$5"
  local out rc before after
  before="$(cat "$outside" 2>/dev/null || echo missing)"
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  after="$(cat "$outside" 2>/dev/null || echo missing)"
  LAST_PLANT_DETAIL="rc=$rc before=$before after=$after rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$before" = "$after" ] \
     && [ "$before" = "ORIGINAL" ] \
     && grep -q 'row|ov_link|v0.43.0|PASS|' "$rec"; then
    return 0
  fi
  return 1
}

# Bind probe segfaults → candidate_gfx unknown, gfx prereq missing with rc.
plant_gfx_crash() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc gfx=$(grep '^candidate_gfx:' <<< "$out" | tr '\n' ' ') rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'candidate_gfx: unknown' <<< "$out" \
     && grep -q 'row|ab_crash|v0.43.0|UNRUNNABLE|' "$rec" \
     && grep -q 'prereq=gfx-build (probe rc 139)' "$rec"; then
    return 0
  fi
  return 1
}

# DMG-shaped self-skip: consumer_skips=1 and not a bare PASS.
plant_gfx_selfskip() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if grep -q 'row|dmg_like|v0.43.0|PASS|skips=1|' "$rec" \
     && grep -q 'consumer_skips=1' "$rec" \
     && ! grep -q 'row|dmg_like|v0.43.0|PASS|0|' "$rec"; then
    return 0
  fi
  return 1
}

# Bare candidate + sibling tree present → exit 2 before any row.
plant_bare_sibling() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc out=$(grep -E 'refusing a bare|VERDICT:|^row|' <<< "$out" | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 2 ] \
     && grep -q 'refusing a bare candidate' <<< "$out" \
     && grep -F -q "$stub" <<< "$out" \
     && grep -F -q "$eco/EigenScript" <<< "$out" \
     && ! grep -q '^row|' "$rec" 2>/dev/null; then
    return 0
  fi
  return 1
}

# sibling_binary_present computed after the wave; no→yes when it changed.
plant_sibling_late() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep -E 'sibling_binary_present' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if grep -q '^sibling_binary_present=no$' "$rec" \
     && grep -q '^sibling_binary_present_after=yes$' "$rec" \
     && grep -q 'sibling_binary_present_changed=no→yes' "$rec"; then
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
        '  local cand="" arg\n',
        '  # CA-GUARD:not-crash\n'
        '  exit 7\n'
        '  local cand="" arg\n',
    ),
    "record-lock": (
        '  # CA-GUARD:record-lock\n'
        '  if ! acquire_record_lock; then\n'
        '    RECORD_FINISHED=1\n'
        '    RUN_RC=2\n'
        '    exit 2\n'
        '  fi',
        '  # CA-GUARD:record-lock\n'
        '  true',
    ),
    "append-owned": (
        '      # CA-GUARD:append-owned\n'
        '      # The ONLY file we may append to without our run_id is a ZERO-BYTE one\n'
        '      # (the in-place clobber after truncate). A nonempty file with no run_id\n'
        '      # line is somebody else\'s content (round-4 residual R11: a replacement\n'
        '      # INCOMPLETE record with no run_id was accepted and the final record read\n'
        '      # PASS with rows missing). And never through a symlink (R7).\n'
        '      if [ -L "$RECORD" ]; then\n'
        '        RECORD_WRITE_ERR="record path is a symlink"\n'
        '        return 1\n'
        '      fi\n'
        '      if [ -s "$RECORD" ] \\\n'
        '         && ! grep -Fx "run_id=${RUN_ID}" "$RECORD" >/dev/null 2>&1; then\n'
        '        RECORD_WRITE_ERR="record not ours"\n'
        '        return 1\n'
        '      fi',
        '      # CA-GUARD:append-owned\n'
        '      true',
    ),
    "die-record-flag": (
        '  # CA-GUARD:die-record-flag\n'
        '  # Leave RECORD_FINISHED=0 when the footer did not land, so the EXIT\n'
        '  # trap\'s finish_incomplete still appends INCOMPLETE or clobbers a\n'
        '  # foreign file. Never a foreign PASS at the path.\n'
        '  if [ "$footer_ok" -eq 1 ]; then\n'
        '    RECORD_FINISHED=1\n'
        '  fi',
        '  # CA-GUARD:die-record-flag\n'
        '  RECORD_FINISHED=1',
    ),
    "stdout-verdict": (
        '  # CA-GUARD:stdout-verdict\n'
        '  case "${RUN_RC:-1}" in\n'
        '    0) emit_stdout_verdict PASS ;;\n'
        '    1) emit_stdout_verdict FAIL ;;\n'
        '    *) emit_stdout_verdict INCOMPLETE ;;\n'
        '  esac',
        '  # CA-GUARD:stdout-verdict\n'
        '  :',
    ),
    "cand-calls": (
        '  # CA-GUARD:cand-calls\n'
        '  # A PASS that never reached the candidate is UNEXERCISED (mechanical-gates\n'
        '  # §113: every arm must prove it RAN). HANG/KILLED/UNRUNNABLE/FAIL keep\n'
        '  # their names -- cand_calls=0 cannot be PASS.\n'
        '  if [ "$LAST_VERDICT" = PASS ] && [ "$LAST_CALLS" -eq 0 ]; then\n'
        '    LAST_VERDICT=UNEXERCISED\n'
        '  fi',
        '  # CA-GUARD:cand-calls\n'
        '  # A PASS that never reached the candidate is UNEXERCISED (mechanical-gates\n'
        '  # §113: every arm must prove it RAN). HANG/KILLED/UNRUNNABLE/FAIL keep\n'
        '  # their names -- cand_calls=0 cannot be PASS.\n'
        '  if false && [ "$LAST_VERDICT" = PASS ] && [ "$LAST_CALLS" -eq 0 ]; then\n'
        '    LAST_VERDICT=UNEXERCISED\n'
        '  fi',
    ),
    "eigs-dir": (
        '  # CA-GUARD:eigs-dir\n'
        '  if [ -n "${CAND_OVERLAY:-}" ]; then',
        '  # CA-GUARD:eigs-dir\n'
        '  if false && [ -n "${CAND_OVERLAY:-}" ]; then',
    ),
    "declared-file": (
        '      # CA-GUARD:declared-file\n'
        '      miss="$(declared_missing_file "$ECO/$r" "$cmd")"\n'
        '      if [ -n "$miss" ]; then',
        '      # CA-GUARD:declared-file\n'
        '      miss="$(declared_missing_file "$ECO/$r" "$cmd")"\n'
        '      if false && [ -n "$miss" ]; then',
    ),
    "prereq": (
        '  # CA-GUARD:prereq\n'
        '  if prereq_tool="$(missing_prereq "$name" "$cmd")"; then',
        '  # CA-GUARD:prereq\n'
        '  if false && prereq_tool="$(missing_prereq "$name" "$cmd")"; then',
    ),
    "eigenscript-bin": (
        '  # CA-GUARD:eigenscript-bin\n'
        '  if true; then',
        '  # CA-GUARD:eigenscript-bin\n'
        '  if false; then',
    ),
    "nontrivial-calls": (
        '      \'# CA-GUARD:nontrivial-calls\' \\\n'
        '      \'kind=probe\' \\',
        '      \'# CA-GUARD:nontrivial-calls\' \\\n'
        '      \'kind=call\' \\',
    ),
    "swallowed": (
        '  # CA-GUARD:swallowed\n'
        '  # Command exited 0 AND no nontrivial candidate invocation succeeded:\n'
        '  # the candidate never once worked and the consumer still reported success.\n'
        '  # A nonzero candidate rc is not by itself a failure (lint/fail-soft).\n'
        '  if [ "$LAST_VERDICT" = PASS ] && [ "${LAST_OK:-0}" -eq 0 ] && [ "${LAST_FAIL:-0}" -gt 0 ]; then\n'
        '    LAST_VERDICT=SWALLOWED\n'
        '  fi',
        '  # CA-GUARD:swallowed\n'
        '  if false && [ "$LAST_VERDICT" = PASS ] && [ "${LAST_OK:-0}" -eq 0 ] && [ "${LAST_FAIL:-0}" -gt 0 ]; then\n'
        '    LAST_VERDICT=SWALLOWED\n'
        '  fi',
    ),

    "gfx-prereq": (
        '      # CA-GUARD:gfx-prereq\n'
        '      if [ "${CAND_HAS_GFX:-0}" != 1 ]; then',
        '      # CA-GUARD:gfx-prereq\n'
        '      if false && [ "${CAND_HAS_GFX:-0}" != 1 ]; then',
    ),
    "finish-incomplete": (
        'finish_incomplete() {\n'
        '  # CA-GUARD:finish-incomplete\n',
        'finish_incomplete() {\n'
        '  # CA-GUARD:finish-incomplete\n'
        '  return 0\n',
    ),
    "clobber-no-follow": (
        '  # CA-GUARD:clobber-no-follow\n'
        '  if [ -L "$RECORD" ]; then\n'
        '    rm -f "$RECORD" || {\n'
        '      RECORD_WRITE_ERR="cannot unlink symlink at $RECORD"\n'
        '      return 1\n'
        '    }\n'
        '  fi',
        '  # CA-GUARD:clobber-no-follow\n'
        '  true',
    ),
    "log-tail": (
        '  # CA-GUARD:log-tail\n'
        '  tailf="$WORK/tail.$name"\n',
        '  # CA-GUARD:log-tail\n'
        '  return 0\n'
        '  tailf="$WORK/tail.$name"\n',
    ),
    "noglob-split": (
        '    # CA-GUARD:noglob-split\n'
        '    local glob_off=0\n'
        '    case "$-" in *f*) glob_off=1 ;; esac\n'
        '    set -f\n',
        '    # CA-GUARD:noglob-split\n'
        '    local glob_off=0\n'
        '    case "$-" in *f*) glob_off=1 ;; esac\n'
        '    set +f\n',
    ),
    "expected-floor": (
        '  # CA-GUARD:expected-floor\n',
        '  # CA-GUARD:expected-floor\n'
        '  EXPECTED_LIST=()\n',
    ),
    "record-floor": (
        '  # CA-GUARD:record-floor\n'
        '  RECORD_FLOOR="$computed"\n',
        '  # CA-GUARD:record-floor\n'
        '  RECORD_FLOOR=0\n',
    ),
    "overlay-retry-rm": (
        '        # CA-GUARD:overlay-retry-rm\n'
        '        rm -rf "$to/$base"\n',
        '        # CA-GUARD:overlay-retry-rm\n'
        '        :\n',
    ),
    "tmp-beside-record": (
        '      # CA-GUARD:tmp-beside-record\n'
        '      dir="$(dirname "$RECORD")"\n',
        '      # CA-GUARD:tmp-beside-record\n'
        '      dir="${WORK:-${TMPDIR:-/tmp}}"\n',
    ),
    "workflow-prefer": (
        '  # CA-GUARD:workflow-prefer\n'
        '  for p in ci.yml tests.yml test.yml; do\n',
        '  # CA-GUARD:workflow-prefer\n'
        '  for p in __none__; do\n',
    ),
    "pause-before-rename": (
        '      if fixture_fault && [ "${CA_FAULT:-}" = pause_before_rename ] && [ "$tag" = rewrite ]; then\n'
        '        sleep 30 &\n'
        '        wait $! || true\n'
        '      fi\n',
        '      if fixture_fault && [ "${CA_FAULT:-}" = pause_before_rename ] && [ "$tag" = rewrite ]; then\n'
        '        RECORD_FINISHED=1\n'
        '        sleep 30 &\n'
        '        wait $! || true\n'
        '      fi\n',
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
    # Gut the file re-read so HUP-after-successful-mv is treated as
    # INCOMPLETE (RECORD_FINISHED still 0 until mv returns to write_record).
    a = (
        '  # CA-GUARD:verdict-from-file\n'
    )
    b = (
        '  # CA-GUARD:verdict-from-file\n'
        '  true\n'
        '  if false; then\n'
    )
    if a not in text:
        sys.stderr.write("mutation finished-after-rename: verdict-from-file not found\n")
        sys.exit(2)
    text = text.replace(a, b, 1)
    # Close the if false so the rest of finish_incomplete still parses.
    needle = (
        '  [ "${RECORD_FINISHED:-0}" -eq 1 ] && return\n'
    )
    repl = (
        '  fi\n'
        '  [ "${RECORD_FINISHED:-0}" -eq 1 ] && return\n'
    )
    if needle not in text:
        sys.stderr.write("mutation finished-after-rename: RECORD_FINISHED early-return not found\n")
        sys.exit(2)
    text = text.replace(needle, repl, 1)
elif kind == "private-log":
    a = (
        "      '# CA-GUARD:private-log' \\\n"
        "      'log=\"$log\"' \\\n"
    )
    b = (
        "      '# CA-GUARD:private-log' \\\n"
        "      'log=\"${CA_CAND_COUNT_FILE:-$log}\"' \\\n"
    )
    if a not in text:
        sys.stderr.write("mutation private-log: shim log needle not found\n")
        sys.exit(2)
    text = text.replace(a, b, 1)
    a2 = (
        '  # CA-GUARD:private-log-export\n'
        '  true\n'
    )
    b2 = (
        '  # CA-GUARD:private-log-export\n'
        '  eigs_exports="${eigs_exports}$(printf \'export CA_CAND_COUNT_FILE=%q\\n\' "$CALL_LOG")"\n'
    )
    if a2 not in text:
        sys.stderr.write("mutation private-log: export needle not found\n")
        sys.exit(2)
    text = text.replace(a2, b2, 1)
    start = "  # CA-GUARD:strip-ca-env\n"
    i = text.find(start)
    if i < 0:
        sys.stderr.write("mutation private-log: strip-ca-env guard not found\n")
        sys.exit(2)
    line_end = text.find("\n", i + len(start))
    if line_end < 0 or "strip_ca=" not in text[i:line_end + 1]:
        sys.stderr.write("mutation private-log: strip_ca assignment not found\n")
        sys.exit(2)
    text = text[:i] + start + "  strip_ca=true" + text[line_end:]
elif kind == "probe-not-attributed":
    pairs = [
        ('run_bounded "$probe_log" "$CAND_ABS" --version',
         'run_bounded "$probe_log" "$SHIM/eigenscript" --version'),
        ('run_bounded "$api_log" "$CAND_ABS" --api --json',
         'run_bounded "$api_log" "$SHIM/eigenscript" --api --json'),
        ('run_bounded "$api_log" "$CAND_ABS" --api',
         'run_bounded "$api_log" "$SHIM/eigenscript" --api'),
        ('run_bounded "$gfx_bind_log" "$CAND_ABS" "$gfx_bind_src"',
         'run_bounded "$gfx_bind_log" "$SHIM/eigenscript" "$gfx_bind_src"'),
        ('    rm -f "$CALL_LOG"\n    : > "$CALL_LOG"\n',
         '    :\n'),
    ]
    for a, b in pairs:
        if a not in text:
            sys.stderr.write("mutation probe-not-attributed: needle not found: %r\n" % (a[:60],))
            sys.exit(2)
        text = text.replace(a, b, 1)
elif kind == "overlay-copy":
    a = (
        '  # CA-GUARD:overlay-copy\n'
        '  overlay_copy_dir() {\n'
    )
    if a not in text:
        sys.stderr.write("mutation overlay-copy: overlay_copy_dir not found\n")
        sys.exit(2)
    # Replace the copy helper with symlink overlay (the original plant Y
    # mechanism): writes through lib/ go to the real tree.
    start = text.find(a)
    end = text.find('  if [ -d "$src/lib" ]; then\n    overlay_copy_dir "$src/lib" "$dst/lib" lib\n  fi\n', start)
    if end < 0:
        sys.stderr.write("mutation overlay-copy: lib copy call not found\n")
        sys.exit(2)
    end = text.find('\n', end + len('  if [ -d "$src/lib" ]; then\n    overlay_copy_dir "$src/lib" "$dst/lib" lib\n  fi'))
    b = (
        '  # CA-GUARD:overlay-copy\n'
        '  mkdir -p "$dst/src"\n'
        '  if [ -d "$src/src" ]; then\n'
        '    for s in "$src/src"/*; do\n'
        '      sb="$(basename "$s")"\n'
        '      if [ "$sb" = eigenscript ]; then\n'
        '        ln -s "$SHIM/eigenscript" "$dst/src/eigenscript"\n'
        '      else\n'
        '        ln -s "$s" "$dst/src/$sb"\n'
        '      fi\n'
        '    done\n'
        '  else\n'
        '    ln -s "$SHIM/eigenscript" "$dst/src/eigenscript"\n'
        '  fi\n'
        '  if [ -d "$src/lib" ]; then\n'
        '    ln -s "$src/lib" "$dst/lib"\n'
        '  fi\n'
    )
    text = text[:start] + b + text[end+1:]
elif kind == "variant-mask":
    start = "  # CA-GUARD:variant-mask\n"
    end = "  # CA-GUARD:end-variant-mask\n"
    # Two blocks (shim install + run_one check). Gut both.
    count = 0
    pos = 0
    while True:
        i = text.find(start, pos)
        j = text.find(end, i if i >= 0 else pos)
        if i < 0 or j < 0 or j < i:
            break
        j += len(end)
        repl = start + "  true\n" + end
        text = text[:i] + repl + text[j:]
        pos = i + len(repl)
        count += 1
        if count > 5:
            break
    if count < 2:
        sys.stderr.write("mutation variant-mask: expected 2 blocks, found %d\n" % count)
        sys.exit(2)
elif kind == "usage-before-record":
    start = "  # CA-GUARD:usage-before-record\n"
    end = "  # CA-GUARD:end-usage-before-record\n"
    i = text.find(start)
    j = text.find(end)
    if i < 0 or j < 0 or j < i:
        sys.stderr.write("mutation usage-before-record: block not found\n")
        sys.exit(2)
    j += len(end)
    text = text[:i] + start + "  : # gutted usage validation\n" + end + text[j:]
elif kind in repls:
    a, b = repls[kind]
    if a not in text:
        sys.stderr.write("mutation %s: needle not found\n" % kind)
        sys.exit(2)
    if kind == "noglob-split":
        text = text.replace(a, b)
        if a in text:
            sys.stderr.write("mutation noglob-split: leftover needle\n")
            sys.exit(2)
    else:
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

# Variant (a): eigenscript-full in a called script AND as a runCmd token,
# stale binary on PATH, no --full. FIRE: both rows UNRUNNABLE|prereq:variant:eigenscript-full,
# stale log empty, each non-PASS row has a log| preflight line.
plant_variant_missing() {
  local sh="$1" eco="$2" stub="$3" rec="$4" stale_log="$5" stale_bin="$6"
  local out rc
  : > "$stale_log"
  out="$(PATH="$(dirname "$stale_bin"):$PATH" CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" \
    "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc stale=$(wc -c < "$stale_log" 2>/dev/null || echo 0) rec=$(grep -E 'row|UNRUNNABLE|^log' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'UNRUNNABLE|prereq:variant:eigenscript-full' <<< "$out" \
     && grep -q 'row|script_user|v0.43.0|UNRUNNABLE|' "$rec" \
     && grep -q 'row|token_user|v0.43.0|UNRUNNABLE|' "$rec" \
     && grep -q '^log|script_user|preflight: prereq:variant:eigenscript-full' "$rec" \
     && grep -q '^log|token_user|preflight: prereq:variant:eigenscript-full' "$rec" \
     && [ ! -s "$stale_log" ]; then
    return 0
  fi
  return 1
}

# Variant (b): same fixture with --full stub. FIRE: PASS, cand_calls counts the full call.
plant_variant_full() {
  local sh="$1" eco="$2" stub="$3" rec="$4" full="$5"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" \
    "$sh" run "$stub" --full "$full" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 0 ] \
     && grep -q 'row|script_user|v0.43.0|PASS|' "$rec" \
     && grep -q 'row|token_user|v0.43.0|PASS|' "$rec" \
     && grep -q 'cand_calls=1' "$rec" \
     && exact_verdict_file "$rec" PASS; then
    return 0
  fi
  return 1
}

# A consumer whose variant name lives in an unusual file. FIRE:
# UNRUNNABLE|prereq:variant:<name>, stale unreached.
plant_variant_named() {
  local sh="$1" eco="$2" stub="$3" rec="$4" stale_log="$5" stale_bin="$6" cname="$7" vname="$8"
  local out rc
  : > "$stale_log"
  out="$(PATH="$(dirname "$stale_bin"):$PATH" CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" \
    "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc name=$vname stale=$(wc -c < "$stale_log" 2>/dev/null || echo 0) rec=$(grep -E 'row|UNRUNNABLE|^log' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q "UNRUNNABLE|prereq:variant:${vname}" <<< "$out" \
     && grep -q "row|${cname}|v0.43.0|UNRUNNABLE|" "$rec" \
     && grep -q "^log|${cname}|preflight: prereq:variant:${vname}" "$rec" \
     && [ ! -s "$stale_log" ]; then
    return 0
  fi
  return 1
}

# B3: 2 consumers, committed-record floor of 3. FIRE: FAIL naming the floor,
# in plan AND in the run record. Discriminates lexical newest (floor 3)
# from mtime (the older-named record is touched newer and has 99 rows).
plant_b3_record_floor() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" "$sh" plan 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="plan rc=$rc $(grep -E 'inventory_floor|VERDICT' <<< "$out" | tr '\n' ' ')"
  note_plant "$out" "" "$rc"
  if [ "$rc" -eq 0 ] || ! grep -q 'inventory 2 < record floor 3' <<< "$out"; then
    return 1
  fi
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)" || true
  LAST_PLANT_DETAIL="$LAST_PLANT_DETAIL run=$(grep -E 'inventory floor|VERDICT' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" 0
  if grep -q '^inventory floor: inventory 2 < record floor 3' "$rec" \
     && grep -q '^inventory floor: inventory 2 < record floor 3' <<< "$out" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# FAIL row carries log|<name>|<line> immediately after the row.
plant_log_tail() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep -E '^row|^log' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'row|log_fail|v0.43.0|FAIL|' "$rec" \
     && grep -q '^log|log_fail|' "$rec"; then
    return 0
  fi
  return 1
}

# B2: declared consumer absent from disk. FIRE: FAIL naming it, in plan
# AND in the run record (the same named line).
plant_b2_missing_declared() {
  local sh="$1" eco="$2" stub="${3:-/bin/true}"
  local out rc rec
  out="$(CA_ECO="$eco" "$sh" plan 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="plan rc=$rc"
  note_plant "$out" "" "$rc"
  if [ "$rc" -eq 0 ] \
     || ! grep -q 'declared consumer absent: missing_one' <<< "$out" \
     || ! grep -q '^VERDICT: FAIL' <<< "$out"; then
    return 1
  fi
  rec="${eco}.b2.run.record"
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)" || true
  LAST_PLANT_DETAIL="$LAST_PLANT_DETAIL run=$(grep -E 'inventory floor|VERDICT|row' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" 0
  if grep -q '^inventory floor: declared consumer absent: missing_one' "$rec" \
     && grep -q '^inventory floor: declared consumer absent: missing_one' <<< "$out" \
     && exact_verdict_file "$rec" FAIL; then
    return 0
  fi
  return 1
}

# Globbing off: declared token tests/*.eigs is literal (plan), AND a runCmd
# with *.eigs in the variant scan does not expand to a variant name (run).
plant_noglob() {
  local sh="$1" eco="$2" cwd="$3" stub="$4"
  local out rc rec
  out="$(cd "$cwd" && CA_ECO="$eco" "$sh" plan 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="plan rc=$rc out=$(grep -E 'GAP|VERDICT:|does not exist' <<< "$out" | tr '\n' ' ')"
  note_plant "$out" "" "$rc"
  if [ "$rc" -eq 0 ] \
     || ! grep -Fq 'tests/*.eigs' <<< "$out" \
     || ! grep -q '^VERDICT: FAIL' <<< "$out"; then
    return 1
  fi
  rec="${cwd}/ng-run.record"
  printf 'x\n' > "$cwd/eigenscript-full.eigs"
  out="$(cd "$cwd" && CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" \
    "$sh" run "$stub" 2>&1)" || true
  LAST_PLANT_DETAIL="$LAST_PLANT_DETAIL run=$(grep -E 'row|UNRUNNABLE|VERDICT' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" 0
  # Positive witness first: the glob_run row exists (the run really ran).
  # Then the negative: the variant loop did not expand *.eigs into a name.
  grep -q '^row|glob_run|' "$rec" 2>/dev/null || return 1
  grep -q '^VERDICT:' "$rec" 2>/dev/null || return 1
  if grep -q 'prereq:variant:eigenscript-full.eigs' "$rec" 2>/dev/null \
     || grep -q 'prereq:variant:eigenscript-full.eigs' <<< "$out"; then
    return 1
  fi
  return 0
}

# J2: signal between footer-write and rename. FIRE: INCOMPLETE, exit 2, file=stdout.
plant_j2_pause_rename() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local pid waited rc n_out outf
  outf="${rec}.stdout"
  rm -f "$outf" "$rec"
  CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_FAULT=pause_before_rename CA_RECORD="$rec" \
    "$sh" run "$stub" >"$outf" 2>&1 &
  pid=$!
  waited=0
  while [ "$waited" -lt 40 ]; do
    if ls "$(dirname "$rec")"/.$(basename "$rec").rewrite.* >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  sleep 0.2
  kill -TERM "$pid" 2>/dev/null || true
  waited=0
  while [ "$waited" -lt 8 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid"
  rc=$?
  n_out="$(grep -c '^VERDICT: INCOMPLETE$' "$outf" 2>/dev/null || true)"
  LAST_PLANT_DETAIL="rc=$rc n_out=$n_out rec=$(grep '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$(cat "$outf" 2>/dev/null || true)" "$rec" "$rc"
  local leftover
  leftover="$(ls "$(dirname "$rec")"/.$(basename "$rec").rewrite.* 2>/dev/null || true)"
  LAST_PLANT_DETAIL="rc=$rc n_out=$n_out leftover=$( [ -n "$leftover" ] && echo yes || echo no ) rec=$(grep '^VERDICT:' "$rec" 2>/dev/null | tr '\n' ' ')"
  if [ "$rc" -eq 2 ] \
     && [ "$n_out" = 1 ] \
     && grep -q '^VERDICT: INCOMPLETE$' "$rec" \
     && grep -q 'status=INCOMPLETE' "$rec" \
     && [ -z "$leftover" ]; then
    return 0
  fi
  return 1
}

# Usage error does not touch the committed record.
plant_usage_no_candidate() {
  local sh="$1" eco="$2" rec="$3"
  local out rc sha1 sha2
  printf '%s\n' '# committed' 'run_id=OLD' 'status=COMPLETE' 'inventory=1 examined=1' 'VERDICT: PASS' > "$rec"
  sha1="$(file_sha256 "$rec")"
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_RECORD="$rec" "$sh" run 2>&1)"
  rc=$?
  sha2="$(file_sha256 "$rec")"
  LAST_PLANT_DETAIL="rc=$rc sha1=$sha1 sha2=$sha2 prev=$( [ -e "${rec}.prev" ] && echo yes || echo no )"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 2 ] \
     && [ "$sha1" = "$sha2" ] \
     && [ ! -e "${rec}.prev" ]; then
    return 0
  fi
  return 1
}

# Temp path's directory equals the record's directory.
plant_show_tmp() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc recdir
  recdir="$(cd "$(dirname "$rec")" && pwd)"
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_FAULT=show_tmp CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc out=$(grep 'record_tmp_dir=' <<< "$out" | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if grep -q "^record_tmp_dir=$recdir$" <<< "$out"; then
    return 0
  fi
  return 1
}

# Prefer tests.yml over bench.yml.
plant_workflow_prefer() {
  local sh="$1" eco="$2"
  local out rc
  out="$(CA_ECO="$eco" "$sh" plan 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc wf=$(grep '^  workflow|' <<< "$out" | tr '\n' ' ')"
  note_plant "$out" "" "$rc"
  if grep -q 'workflow|pref_user|tests.yml' <<< "$out" \
     && ! grep -q 'workflow|pref_user|bench.yml' <<< "$out"; then
    return 0
  fi
  return 1
}

# a.yml + b.yml, no preferred name → UNRUNNABLE by name.
plant_workflow_ambiguous() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc out=$(grep -E 'UNRUNNABLE|ambiguous' <<< "$out" | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 1 ] \
     && grep -q 'UNRUNNABLE|ambiguous-workflow:' <<< "$out" \
     && grep -q 'a.yml' <<< "$out" \
     && grep -q 'b.yml' <<< "$out"; then
    return 0
  fi
  return 1
}

# Partial overlay retry does not nest src/data/data/x.
plant_overlay_partial() {
  local sh="$1" eco="$2" stub="$3" rec="$4"
  local out rc
  out="$(CA_ECO="$eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_FAULT=overlay_partial CA_RECORD="$rec" "$sh" run "$stub" 2>&1)"
  rc=$?
  LAST_PLANT_DETAIL="rc=$rc rec=$(grep '^row|' "$rec" 2>/dev/null | tr '\n' ' ')"
  note_plant "$out" "$rec" "$rc"
  if [ "$rc" -eq 0 ] \
     && grep -q 'row|ovp_user|v0.43.0|PASS|' "$rec" \
     && exact_verdict_file "$rec" PASS; then
    return 0
  fi
  return 1
}

selftest() {
  local st_root rec out rc pid outer_tmp
  ST_FAIL=0
  ST_SKIP=0
  ST_RUNS=0
  ST_UNBOUND=0
  ST_PLANTS=0
  outer_tmp="${TMPDIR:-/tmp}"
  st_root="$(mktemp -d "${outer_tmp}/ca-st.XXXXXX")"
  mkdir -p "$st_root/tmp"
  export TMPDIR="$st_root/tmp"
  trap 'if [ -n "${st_root:-}" ] && [ -d "${st_root:-}" ]; then find "$st_root" -type d -exec chmod u+w {} + 2>/dev/null || true; rm -rf "$st_root"; fi' EXIT

  local sh
  sh="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  mk_stub "$st_root/stub-ok" 0
  mk_stub "$st_root/stub-bad" 1
  mk_stub_gfx "$st_root/stub-gfx"

  if python3 "$HERE/tools/_extract_runcmd.py" --selftest >/dev/null; then
    plant_line "extract-runcmd" 0 "SELFTEST: PASS examined=7"
  else
    plant_line "extract-runcmd" 1 "extractor --selftest failed"
  fi

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
  mk_consumer "$good_eco" good_a "eigenscript work.eigs"
  mk_consumer "$good_eco" good_b '$EIGS work.eigs'
  rec="$st_root/good.record"
  if plant_honest_good "$sh" "$good_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "control honest-good" 0 "VERDICT: PASS inventory=2 examined=2"
  else
    plant_line "control honest-good" 1 "$LAST_PLANT_DETAIL"
  fi

  # Plan on the same honest fixture must still PASS (plan mode unchanged).
  out="$(CA_ECO="$good_eco" "$sh" plan 2>&1)" || true
  if grep -q 'VERDICT: PASS -- 2 consumers' <<< "$out"; then
    plant_line "plan-control" 0 "plan still PASSes a 2-consumer fixture"
  else
    plant_line "plan-control" 1 "plan did not PASS the honest fixture"
  fi

  # SKIP rows exist ONLY for EXCLUDED names, and they are not examined.
  local skip_eco="$st_root/skip-eco"
  mkdir -p "$skip_eco"
  printf 'fixture\n' > "$skip_eco/.ca_fixture"
  mk_consumer "$skip_eco" keep "eigenscript work.eigs"
  mk_consumer "$skip_eco" tmp "eigenscript work.eigs"
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
  mk_consumer "$a_eco" a_one "eigenscript work.eigs"
  mk_consumer "$a_eco" a_two "eigenscript work.eigs"
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
  mk_consumer "$b_eco" keep "eigenscript work.eigs"
  mk_consumer "$b_eco" victim "eigenscript work.eigs"
  printf '%s\n' keep victim > "$b_eco/.ca_expected"
  rec="$st_root/b.record"
  out="$(CA_ECO="$b_eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_DROP_BEFORE=victim CA_RECORD="$rec" "$sh" run "$st_root/stub-ok" 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ] \
     && exact_verdict_file "$rec" FAIL \
     && grep -q 'row|victim|' "$rec" \
     && grep -q '|UNRUNNABLE|' "$rec" \
     && grep -q 'inventory=2 examined=2' "$rec"; then
    plant_line "B shrinkage" 0 "UNRUNNABLE victim (declared-absent before scan), examined=2 inventory=2, VERDICT: FAIL"
  else
    plant_line "B shrinkage" 1 "rc=$rc rec=$(grep -E '^row|inventory=' "$rec" 2>/dev/null | tr '\n' ' ')"
  fi

  # --- C: hang -- sleep past budget; HANG by name; run continues.
  local c_eco="$st_root/c-eco"
  mkdir -p "$c_eco"
  printf 'fixture\n' > "$c_eco/.ca_fixture"
  mk_consumer "$c_eco" aaa_sleep "sleep 30"
  mk_consumer "$c_eco" zzz_pass "eigenscript work.eigs"
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
  mk_consumer "$k_eco" zzz_ok "eigenscript work.eigs"
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
  mk_consumer "$d_eco" zzz_after "eigenscript work.eigs"
  rec="$st_root/d.record"
  if plant_interruption "$sh" "$d_eco" "$st_root/stub-ok" "$rec" TERM; then
    plant_line "D interruption" 0 "record INCOMPLETE, exactly one stdout VERDICT: INCOMPLETE, exit 2"
  else
    plant_line "D interruption" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- D2: SIGHUP is trapped the same way (exit 2, not 129).
  local dh_eco="$st_root/dh-eco"
  mkdir -p "$dh_eco"
  printf 'fixture\n' > "$dh_eco/.ca_fixture"
  mk_consumer "$dh_eco" aaa_block "sleep 30"
  mk_consumer "$dh_eco" zzz_after "eigenscript work.eigs"
  rec="$st_root/dh.record"
  if plant_interruption "$sh" "$dh_eco" "$st_root/stub-ok" "$rec" HUP; then
    plant_line "D2 sighup" 0 "SIGHUP -> INCOMPLETE, exactly one stdout VERDICT: INCOMPLETE, exit 2"
  else
    plant_line "D2 sighup" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- E: hanging --version probe; stale PASS at the record path is gone.
  local e_eco="$st_root/e-eco"
  mkdir -p "$e_eco"
  printf 'fixture\n' > "$e_eco/.ca_fixture"
  mk_consumer "$e_eco" e_one "eigenscript work.eigs"
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
  mk_consumer "$f_eco" f_one "eigenscript work.eigs"
  ro_dir="$st_root/ro"
  mkdir -p "$ro_dir"
  rec_f="$ro_dir/record"
  chmod a-w "$ro_dir"
  out="$(CA_ECO="$f_eco" CA_TIMEOUT=5 CA_KILL_AFTER=1 CA_RECORD="$rec_f" "$sh" run "$st_root/stub-ok" 2>&1)"
  rc=$?
  chmod u+w "$ro_dir"
  if [ "$rc" -eq 1 ] \
     && ! grep -q 'VERDICT: PASS' <<< "$out" \
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
  mk_consumer "$es_eco" aaa "eigenscript work.eigs"
  mk_consumer "$es_eco" bbb "eigenscript work.eigs"
  mk_consumer "$es_eco" ccc "eigenscript work.eigs"
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
  mk_consumer "$z_eco" tmp "eigenscript work.eigs"
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
  mk_consumer "$sr_eco" keep "eigenscript work.eigs"
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
    mk_consumer_padded "$h_eco" "c$(printf '%02d' "$hi")" "eigenscript work.eigs"
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
  mk_consumer "$i_eco" i_one "eigenscript work.eigs"
  rec="$st_root/i-ro/record"
  plant_stale_unwritable "$sh" "$i_eco" "$st_root/stub-ok" "$rec"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    plant_line "I stale-unwritable" 0 "record not PASS, exit 1"
  elif [ "$rc" -eq 3 ]; then
    say "plant I stale-unwritable: SKIP -- $LAST_PLANT_DETAIL"
    ST_SKIP=$((ST_SKIP + 1))
  else
    plant_line "I stale-unwritable" 1 "$LAST_PLANT_DETAIL"
  fi
  # Fixture-gated pretend_root: the plant takes the named SKIP path (or, as
  # real root with a usable drop tool, FIREs under the unprivileged user).
  CA_FAULT=pretend_root plant_stale_unwritable "$sh" "$i_eco" "$st_root/stub-ok" "$st_root/i-ro/pretend"
  rc=$?
  if [ "$rc" -eq 3 ] && [ "${LAST_PLANT_DETAIL#SKIP \(root: }" != "$LAST_PLANT_DETAIL" ]; then
    plant_line "I stale-unwritable-root" 0 "$LAST_PLANT_DETAIL"
  elif [ "$rc" -eq 0 ]; then
    plant_line "I stale-unwritable-root" 0 "unprivileged drop FIRE -- $LAST_PLANT_DETAIL"
  else
    plant_line "I stale-unwritable-root" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- J: signal during finalization -- exactly one VERDICT line, rc, stdout.
  local j_eco="$st_root/j-eco" j_shim="$st_root/j-shim"
  mkdir -p "$j_eco" "$j_shim"
  printf 'fixture\n' > "$j_eco/.ca_fixture"
  mk_consumer "$j_eco" j_one "eigenscript work.eigs"
  printf '%s\n' '#!/bin/bash' '/usr/bin/mv "$@" || exit $?' 'case "$1" in *.rewrite.*) kill -HUP "$PPID" ;; esac' 'exit 0' > "$j_shim/mv"
  chmod +x "$j_shim/mv"
  rec="$st_root/j.record"
  if plant_footer_signal "$sh" "$j_eco" "$st_root/stub-ok" "$rec" "$j_shim"; then
    plant_line "J footer-signal" 0 "exactly one VERDICT line, rc=0, stdout PASS"
  else
    plant_line "J footer-signal" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- N: second invocation on the same CA_RECORD is refused.
  local n_eco_a="$st_root/n-eco-a" n_eco_b="$st_root/n-eco-b"
  mkdir -p "$n_eco_a" "$n_eco_b"
  printf 'fixture\n' > "$n_eco_a/.ca_fixture"
  printf 'fixture\n' > "$n_eco_b/.ca_fixture"
  mk_consumer "$n_eco_a" aa_slow "eigenscript work.eigs; sleep 3"
  mk_consumer "$n_eco_b" aa_bad "eigenscript work.eigs"
  rec="$st_root/n.record"
  if plant_record_busy "$sh" "$n_eco_a" "$n_eco_b" "$st_root/stub-ok" "$st_root/stub-bad" "$rec"; then
    plant_line "N record-busy" 0 "second run exit 2 busy, first PASS one VERDICT"
  else
    plant_line "N record-busy" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- O: foreign-file append refused, clobbered in place.
  local o_eco="$st_root/o-eco"
  mkdir -p "$o_eco"
  printf 'fixture\n' > "$o_eco/.ca_fixture"
  mk_consumer "$o_eco" o_one "eigenscript work.eigs"
  rec="$st_root/o.record"
  if plant_foreign_record "$sh" "$o_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "O foreign-record" 0 "record not ours, foreign PASS clobbered, exit 1"
  else
    plant_line "O foreign-record" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- P: die_record after a failed footer still lands INCOMPLETE.
  local p_eco="$st_root/p-eco"
  mkdir -p "$p_eco"
  printf 'fixture\n' > "$p_eco/.ca_fixture"
  mk_consumer "$p_eco" p_one "eigenscript work.eigs"
  rec="$st_root/p.record"
  if plant_fail_footer "$sh" "$p_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "P fail-footer" 0 "footer fail, finish_incomplete lands INCOMPLETE"
  else
    plant_line "P fail-footer" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- Q: stdout verdict on HUP-after-rename (J's scenario, rc + stdout).
  rec="$st_root/q.record"
  if plant_footer_signal "$sh" "$j_eco" "$st_root/stub-ok" "$rec" "$j_shim"; then
    plant_line "Q stdout-hup" 0 "HUP-after-rename rc=0, one stdout VERDICT: PASS"
  else
    plant_line "Q stdout-hup" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- K: CA_TIMEOUT=0 and 00 both exit 2.
  # Not k_eco: C2 already bound that name to the kill fixture.
  local tz_eco="$st_root/tz-eco"
  mkdir -p "$tz_eco"
  printf 'fixture\n' > "$tz_eco/.ca_fixture"
  mk_consumer "$tz_eco" tz_one "eigenscript work.eigs"
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
  mk_consumer_block "$l_eco" pipe_fail "false | true" "eigenscript work.eigs"
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

  # Decoy in the OUTER tmp (a concurrent run's scratch). Must survive plant M.
  # $$ so two concurrent self-tests do not share one path.
  local decoy="$outer_tmp/ca-run.DECOY.$$"
  mkdir -p "$decoy"
  touch "$decoy"
  rec="$st_root/m-decoy.record"
  if plant_scratch_cleanup "$sh" "$good_eco" "$st_root/stub-ok" "$rec" \
     && [ -d "$decoy" ]; then
    plant_line "M decoy-tmp-isolation" 0 "outer ca-run.DECOY survived plant M"
  else
    plant_line "M decoy-tmp-isolation" 1 "decoy=$( [ -d "$decoy" ] && echo live || echo gone ) $LAST_PLANT_DETAIL"
  fi
  rm -rf "$decoy"

  # --- R: `true` never calls the candidate -> UNEXERCISED.
  local r_eco="$st_root/r-eco"
  mkdir -p "$r_eco"
  printf 'fixture\n' > "$r_eco/.ca_fixture"
  mk_consumer "$r_eco" r_true "true"
  rec="$st_root/r.record"
  if plant_unexercised "$sh" "$r_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "R unexercised" 0 "true -> UNEXERCISED cand_calls=0, VERDICT: FAIL"
  else
    plant_line "R unexercised" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- S: tree consumer via EIGS_DIR/src/eigenscript -> PASS cand_calls=1.
  local s_eco="$st_root/s-eco" s_stub="$st_root/s-cand/src/eigenscript"
  mkdir -p "$s_eco" "$st_root/s-cand/src"
  printf 'fixture\n' > "$s_eco/.ca_fixture"
  mk_stub "$s_stub" 0
  mk_consumer "$s_eco" tree_user '"$EIGS_DIR/src/eigenscript" work.eigs'
  rec="$st_root/s.record"
  if plant_tree_consumer "$sh" "$s_eco" "$s_stub" "$rec"; then
    plant_line "S tree-consumer" 0 "EIGS_DIR/src/eigenscript work.eigs PASS cand_calls=1"
  else
    plant_line "S tree-consumer" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- T: DECLARED command names a nonexistent file -> plan GAP.
  local t_eco="$st_root/t-eco"
  mkdir -p "$t_eco"
  printf 'fixture\n' > "$t_eco/.ca_fixture"
  mk_consumer "$t_eco" t_miss ""
  printf 'bash tests/does_not_exist.sh\n' > "$t_eco/t_miss/.ca_declared"
  if CA_ECO="$t_eco" plant_declared_missing "$sh" "$t_eco"; then
    plant_line "T declared-missing" 0 "GAP declared command's file does not exist"
  else
    plant_line "T declared-missing" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- U: PREREQS=nonexistent-tool -> UNRUNNABLE|prereq:nonexistent-tool.
  local u_eco="$st_root/u-eco"
  mkdir -p "$u_eco"
  printf 'fixture\n' > "$u_eco/.ca_fixture"
  mk_consumer "$u_eco" u_prereq "eigenscript work.eigs"
  printf 'nonexistent-tool\n' > "$u_eco/u_prereq/.ca_prereqs"
  rec="$st_root/u.record"
  if plant_prereq_missing "$sh" "$u_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "U prereq-missing" 0 "UNRUNNABLE|prereq:nonexistent-tool"
  else
    plant_line "U prereq-missing" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- V: forged call| lines via CA_CAND_COUNT_FILE -> UNEXERCISED.
  local v_eco="$st_root/v-eco"
  mkdir -p "$v_eco"
  printf 'fixture\n' > "$v_eco/.ca_fixture"
  mk_consumer "$v_eco" v_forge 'printf "call|rc=0|forged\n" >> "${CA_CAND_COUNT_FILE:-/dev/null}"'
  rec="$st_root/v.record"
  if plant_forged_counter "$sh" "$v_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "V forged-counter" 0 "call| write -> UNEXERCISED cand_calls=0"
  else
    plant_line "V forged-counter" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- W: version-only -> UNEXERCISED.
  local w_eco="$st_root/w-eco"
  mkdir -p "$w_eco"
  printf 'fixture\n' > "$w_eco/.ca_fixture"
  mk_consumer "$w_eco" w_ver "eigenscript --version"
  rec="$st_root/w.record"
  if plant_version_only "$sh" "$w_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "W version-only" 0 "--version -> UNEXERCISED cand_calls=0"
  else
    plant_line "W version-only" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- X: swallowed rc (eigenscript bad.eigs || true) -> SWALLOWED.
  local x_eco="$st_root/x-eco"
  mkdir -p "$x_eco"
  printf 'fixture\n' > "$x_eco/.ca_fixture"
  mk_consumer "$x_eco" x_swall "eigenscript bad.eigs || true"
  rec="$st_root/x.record"
  if plant_swallowed "$sh" "$x_eco" "$st_root/stub-bad" "$rec"; then
    plant_line "X swallowed" 0 "bad.eigs || true -> SWALLOWED cand_ok=0 cand_fail=1"
  else
    plant_line "X swallowed" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- Y: overlay COPY -- write does not touch candidate lib/; realpath counted.
  local y_eco="$st_root/y-eco" y_stub="$st_root/y-cand/src/eigenscript"
  mkdir -p "$y_eco" "$st_root/y-cand/src" "$st_root/y-cand/lib"
  printf 'fixture\n' > "$y_eco/.ca_fixture"
  printf 'original\n' > "$st_root/y-cand/lib/marker"
  mk_stub "$y_stub" 0
  mk_consumer_block "$y_eco" y_ov \
    'printf "changed\n" > "$EIGS_DIR/lib/marker"' \
    'rp=$(realpath "$EIGS_DIR/src/eigenscript")' \
    '"$rp" work.eigs'
  rec="$st_root/y.record"
  if plant_overlay_write "$sh" "$y_eco" "$y_stub" "$rec"; then
    plant_line "Y overlay-write" 0 "lib checksum unchanged, realpath cand_calls=1 PASS"
  else
    plant_line "Y overlay-write" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- Z: consumer runs nothing; stub lists gfx_open so the bind probe
  # (a positional) exists to mis-attribute if the mechanism is gutted.
  local z_idle_eco="$st_root/z-idle-eco"
  mkdir -p "$z_idle_eco"
  printf 'fixture\n' > "$z_idle_eco/.ca_fixture"
  mk_consumer "$z_idle_eco" z_idle "true"
  rec="$st_root/z-idle.record"
  if plant_probe_not_attributed "$sh" "$z_idle_eco" "$st_root/stub-gfx" "$rec"; then
    plant_line "Z probe-not-attributed" 0 "true + gfx stub -> cand_calls=0 UNEXERCISED"
  else
    plant_line "Z probe-not-attributed" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- AA: EIGENSCRIPT_BIN beats a sibling hard-path.
  local aa_eco="$st_root/aa-eco" aa_stub="$st_root/aa-cand/src/eigenscript"
  mkdir -p "$aa_eco" "$st_root/aa-cand/src" "$aa_eco/aa_route/tests" \
           "$aa_eco/EigenScript/src"
  printf 'fixture\n' > "$aa_eco/.ca_fixture"
  mk_stub "$aa_stub" 0
  printf '%s\n' '#!/bin/sh' \
    "printf 'sibling:%s\\n' \"\$*\" >> \"$st_root/aa-sibling.log\"" \
    'exit 0' > "$aa_eco/EigenScript/src/eigenscript"
  chmod +x "$aa_eco/EigenScript/src/eigenscript"
  : > "$st_root/aa-sibling.log"
  printf '%s\n' '#!/bin/sh' \
    'ROOT="$(cd "$(dirname "$0")/.." && pwd)"' \
    'if [ -n "${EIGENSCRIPT_BIN:-}" ]; then' \
    '  BIN="$EIGENSCRIPT_BIN"' \
    'elif [ -x "$ROOT/../EigenScript/src/eigenscript" ]; then' \
    '  BIN="$ROOT/../EigenScript/src/eigenscript"' \
    'else' \
    '  BIN=eigenscript' \
    'fi' \
    '"$BIN" work.eigs' > "$aa_eco/aa_route/tests/run.sh"
  chmod +x "$aa_eco/aa_route/tests/run.sh"
  mk_consumer "$aa_eco" aa_route "bash tests/run.sh"
  rec="$st_root/aa.record"
  if plant_bin_routing "$sh" "$aa_eco" "$aa_stub" "$rec"; then
    plant_line "AA eigenscript-bin" 0 "EIGENSCRIPT_BIN routes to shim, sibling log empty, PASS"
  else
    plant_line "AA eigenscript-bin" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- AB: gfx PREREQS, stub --api omits gfx_open -> UNRUNNABLE|prereq:gfx-build.
  local ab_eco="$st_root/ab-eco"
  mkdir -p "$ab_eco"
  printf 'fixture\n' > "$ab_eco/.ca_fixture"
  mk_consumer "$ab_eco" ab_gfx "eigenscript work.eigs"
  printf 'gfx\n' > "$ab_eco/ab_gfx/.ca_prereqs"
  rec="$st_root/ab.record"
  if plant_gfx_prereq "$sh" "$ab_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "AB gfx-prereq" 0 "UNRUNNABLE|prereq:gfx-build"
  else
    plant_line "AB gfx-prereq" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- AC: clobber must not truncate through a symlink. Victim keeps its bytes.
  local ac_eco="$st_root/ac-eco"
  mkdir -p "$ac_eco"
  printf 'fixture\n' > "$ac_eco/.ca_fixture"
  mk_consumer "$ac_eco" ac_swap "eigenscript work.eigs"
  rec="$st_root/ac.record"
  if plant_clobber_symlink "$sh" "$ac_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "AC clobber-symlink" 0 "victim keeps its bytes"
  else
    plant_line "AC clobber-symlink" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- straggler: row N's background call must not land in row N+1.
  local st_eco="$st_root/st-eco"
  mkdir -p "$st_eco"
  printf 'fixture\n' > "$st_eco/.ca_fixture"
  mk_consumer_block "$st_eco" a_leaves_bg \
    'eigenscript work.eigs' \
    '( sleep 2; eigenscript straggler.eigs ) > /dev/null 2>&1 &' \
    'exit 0'
  mk_consumer_block "$st_eco" b_never_calls 'sleep 1' 'true'
  rec="$st_root/straggler.record"
  if plant_straggler "$sh" "$st_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "straggler" 0 "b_never_calls UNEXERCISED"
  else
    plant_line "straggler" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- export-block join: EIGENSCRIPT_DIR equals EIGS_DIR, ends in cand_tree.
  local exp_eco="$st_root/exp-eco" exp_stub="$st_root/exp-cand/src/eigenscript"
  mkdir -p "$exp_eco" "$st_root/exp-cand/src"
  printf 'fixture\n' > "$exp_eco/.ca_fixture"
  mk_stub "$exp_stub" 0
  mk_consumer_block "$exp_eco" exp_join \
    'case "$EIGENSCRIPT_DIR" in "$EIGS_DIR") ;; *) exit 1 ;; esac' \
    'case "$EIGS_DIR" in */cand_tree) ;; *) exit 1 ;; esac' \
    'eigenscript work.eigs'
  rec="$st_root/exp.record"
  if plant_exports_join "$sh" "$exp_eco" "$exp_stub" "$rec"; then
    plant_line "exports-join" 0 "EIGENSCRIPT_DIR equals EIGS_DIR and ends in cand_tree"
  else
    plant_line "exports-join" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- private log: find every regular file under shim parent and EIGS_DIR.
  local pf_eco="$st_root/pf-eco"
  mkdir -p "$pf_eco"
  printf 'fixture\n' > "$pf_eco/.ca_fixture"
  mk_consumer_block "$pf_eco" priv_find \
    'W="$(dirname "$(dirname "$(command -v eigenscript)")")"' \
    'E="${EIGS_DIR:-}"' \
    'find "$W" ${E:+"$E"} -type f 2>/dev/null | while IFS= read -r f; do' \
    '  printf "call|rc=0|x\n" >> "$f" 2>/dev/null || true' \
    'done' \
    'true'
  rec="$st_root/pf.record"
  if plant_private_find "$sh" "$pf_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "private-find" 0 "find+forge under shim parent and EIGS_DIR -> UNEXERCISED"
  else
    plant_line "private-find" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- overlay symlink: write through lib/link must not change the outside file.
  local ovl_eco="$st_root/ovl-eco" ovl_stub="$st_root/ovl-cand/src/eigenscript"
  local ovl_out="$st_root/ovl-outside"
  mkdir -p "$ovl_eco" "$st_root/ovl-cand/src" "$st_root/ovl-cand/lib"
  printf 'fixture\n' > "$ovl_eco/.ca_fixture"
  printf 'ORIGINAL\n' > "$ovl_out"
  ln -s "$ovl_out" "$st_root/ovl-cand/lib/link"
  mk_stub "$ovl_stub" 0
  mk_consumer_block "$ovl_eco" ov_link \
    'printf CHANGED > "$EIGS_DIR/lib/link"' \
    'eigenscript work.eigs'
  rec="$st_root/ovl.record"
  if plant_overlay_symlink "$sh" "$ovl_eco" "$ovl_stub" "$rec" "$ovl_out"; then
    plant_line "overlay-symlink" 0 "outside file unchanged"
  else
    plant_line "overlay-symlink" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- gfx bind probe segfaults -> unknown, gfx prereq missing with rc 139.
  local gc_eco="$st_root/gc-eco" gc_stub="$st_root/stub-segv"
  mkdir -p "$gc_eco"
  printf 'fixture\n' > "$gc_eco/.ca_fixture"
  printf '%s\n' '#!/bin/sh' \
    'if [ "${1:-}" = --version ]; then echo stub; exit 0; fi' \
    'if [ "${1:-}" = --api ]; then echo "{\"builtins\":[\"gfx_open\"]}"; exit 0; fi' \
    'case "$1" in *gfx_bind.eigs) exit 139 ;; esac' \
    'exit 0' > "$gc_stub"
  chmod +x "$gc_stub"
  mk_consumer "$gc_eco" ab_crash "eigenscript work.eigs"
  printf 'gfx\n' > "$gc_eco/ab_crash/.ca_prereqs"
  rec="$st_root/gc.record"
  if plant_gfx_crash "$sh" "$gc_eco" "$gc_stub" "$rec"; then
    plant_line "gfx-crash" 0 "candidate_gfx unknown, UNRUNNABLE prereq:gfx-build (probe rc 139)"
  else
    plant_line "gfx-crash" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- DMG-shaped self-skip: consumer_skips=1, not a bare PASS.
  local gs_eco="$st_root/gs-eco"
  mkdir -p "$gs_eco/dmg_like/tests"
  printf 'fixture\n' > "$gs_eco/.ca_fixture"
  cat > "$gs_eco/dmg_like/tests/run_debug_ui_oracle.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${EIGENSCRIPT_GFX:-}" ]; then E="$EIGENSCRIPT_GFX"; elif command -v eigenscript >/dev/null; then E="$(command -v eigenscript)"; else echo "SKIP: no binary"; exit 0; fi
if ! "$E" tests/probe_ui.eigs >/dev/null 2>&1; then echo "SKIP: dock widget not in this runtime's lib (self-skip, exit 0)"; exit 0; fi
echo "UI ORACLE RAN"; exit 1
EOS
  chmod +x "$gs_eco/dmg_like/tests/run_debug_ui_oracle.sh"
  mk_consumer_block "$gs_eco" dmg_like \
    'eigenscript tests/test_cpu.eigs' \
    'bash tests/run_debug_ui_oracle.sh'
  rec="$st_root/gs.record"
  printf '%s\n' '#!/bin/sh' \
    'if [ "${1:-}" = --version ]; then echo stub; exit 0; fi' \
    'if [ "${1:-}" = --api ]; then echo "{\"builtins\":[]}"; exit 0; fi' \
    'case "$1" in *probe_ui.eigs) echo "undefined variable gfx_open" >&2; exit 1;; esac' \
    'exit 0' > "$st_root/stub-headless"
  chmod +x "$st_root/stub-headless"
  if plant_gfx_selfskip "$sh" "$gs_eco" "$st_root/stub-headless" "$rec"; then
    plant_line "gfx-selfskip" 0 "PASS|skips=1 consumer_skips=1"
  else
    plant_line "gfx-selfskip" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- bare candidate + sibling tree -> exit 2 before any row.
  local bs_eco="$st_root/bs-eco"
  mkdir -p "$bs_eco/tree_user" "$bs_eco/EigenScript/src"
  printf 'fixture\n' > "$bs_eco/.ca_fixture"
  mk_stub "$bs_eco/EigenScript/src/eigenscript" 0
  mk_consumer "$bs_eco" tree_user "eigenscript work.eigs"
  rec="$st_root/bs.record"
  if plant_bare_sibling "$sh" "$bs_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "bare-sibling" 0 "exit 2, names both paths, no row"
  else
    plant_line "bare-sibling" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- sibling_binary_present after the wave; no→yes when a consumer created it.
  local sl_eco="$st_root/sl-eco"
  mkdir -p "$sl_eco"
  printf 'fixture\n' > "$sl_eco/.ca_fixture"
  mk_stub "$st_root/sl-template" 0
  mk_consumer_block "$sl_eco" sib_late \
    'eigenscript work.eigs' \
    'mkdir -p ../EigenScript/src' \
    "cp \"$st_root/sl-template\" ../EigenScript/src/eigenscript"
  rec="$st_root/sl.record"
  if plant_sibling_late "$sh" "$sl_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "sibling-late" 0 "sibling_binary_present no→yes after the wave"
  else
    plant_line "sibling-late" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- variant (a): eigenscript-full in a called script AND as a token.
  local var_eco="$st_root/var-eco" stale_dir="$st_root/stale-bin" stale_log="$st_root/stale-full.log"
  mkdir -p "$var_eco" "$stale_dir"
  printf 'fixture\n' > "$var_eco/.ca_fixture"
  mk_consumer "$var_eco" script_user "bash run.sh"
  printf '%s\n' '#!/bin/sh' 'eigenscript-full work.eigs' > "$var_eco/script_user/run.sh"
  chmod +x "$var_eco/script_user/run.sh"
  mk_consumer "$var_eco" token_user "eigenscript-full work.eigs"
  printf '%s\n' '#!/bin/sh' \
    "printf 'stale:%s\\n' \"\$*\" >> \"$stale_log\"" \
    'echo stale-full-version; exit 0' > "$stale_dir/eigenscript-full"
  chmod +x "$stale_dir/eigenscript-full"
  : > "$stale_log"
  rec="$st_root/var-a.record"
  if plant_variant_missing "$sh" "$var_eco" "$st_root/stub-ok" "$rec" "$stale_log" "$stale_dir/eigenscript-full"; then
    plant_line "variant-missing" 0 "UNRUNNABLE|prereq:variant:eigenscript-full both rows, stale empty, log|"
  else
    plant_line "variant-missing" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- variant (b): --full stub → PASS cand_calls=1.
  rec="$st_root/var-b.record"
  if plant_variant_full "$sh" "$var_eco" "$st_root/stub-ok" "$rec" "$st_root/stub-ok"; then
    plant_line "variant-full" 0 "PASS cand_calls=1 with --full"
  else
    plant_line "variant-full" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- name in a .py and a Makefile; multi-hyphen; extensionless script.
  local py_eco="$st_root/py-eco" mf_eco="$st_root/mf-eco"
  local mh_eco="$st_root/mh-eco" ex_eco="$st_root/ex-eco"
  local stale_jit="$st_root/stale-jit.log" stale_gfx="$st_root/stale-gfx.log"
  local stale_http="$st_root/stale-http.log" stale_dbg="$st_root/stale-dbg.log"
  mkdir -p "$py_eco" "$mf_eco" "$mh_eco" "$ex_eco" "$stale_dir"
  printf 'fixture\n' > "$py_eco/.ca_fixture"
  printf 'fixture\n' > "$mf_eco/.ca_fixture"
  printf 'fixture\n' > "$mh_eco/.ca_fixture"
  printf 'fixture\n' > "$ex_eco/.ca_fixture"
  mk_consumer "$py_eco" py_user "eigenscript work.eigs"
  printf 'os.system("eigenscript-jit x")\n' > "$py_eco/py_user/run.py"
  printf '%s\n' '#!/bin/sh' "printf stale >> \"$stale_jit\"" 'exit 0' > "$stale_dir/eigenscript-jit"
  chmod +x "$stale_dir/eigenscript-jit"
  : > "$stale_jit"
  rec="$st_root/var-py.record"
  if plant_variant_named "$sh" "$py_eco" "$st_root/stub-ok" "$rec" "$stale_jit" "$stale_dir/eigenscript-jit" py_user eigenscript-jit; then
    plant_line "variant-py" 0 "UNRUNNABLE|prereq:variant:eigenscript-jit from .py"
  else
    plant_line "variant-py" 1 "$LAST_PLANT_DETAIL"
  fi
  mk_consumer "$mf_eco" mf_user "eigenscript work.eigs"
  printf 'run:\n\teigenscript-gfx x\n' > "$mf_eco/mf_user/Makefile"
  printf '%s\n' '#!/bin/sh' "printf stale >> \"$stale_gfx\"" 'exit 0' > "$stale_dir/eigenscript-gfx"
  chmod +x "$stale_dir/eigenscript-gfx"
  : > "$stale_gfx"
  rec="$st_root/var-mf.record"
  if plant_variant_named "$sh" "$mf_eco" "$st_root/stub-ok" "$rec" "$stale_gfx" "$stale_dir/eigenscript-gfx" mf_user eigenscript-gfx; then
    plant_line "variant-makefile" 0 "UNRUNNABLE|prereq:variant:eigenscript-gfx from Makefile"
  else
    plant_line "variant-makefile" 1 "$LAST_PLANT_DETAIL"
  fi
  mk_consumer "$mh_eco" mh_user "bash run.sh"
  printf '%s\n' '#!/bin/sh' 'eigenscript-http-model work.eigs' > "$mh_eco/mh_user/run.sh"
  chmod +x "$mh_eco/mh_user/run.sh"
  printf '%s\n' '#!/bin/sh' "printf stale >> \"$stale_http\"" 'exit 0' > "$stale_dir/eigenscript-http-model"
  chmod +x "$stale_dir/eigenscript-http-model"
  : > "$stale_http"
  rec="$st_root/var-mh.record"
  if plant_variant_named "$sh" "$mh_eco" "$st_root/stub-ok" "$rec" "$stale_http" "$stale_dir/eigenscript-http-model" mh_user eigenscript-http-model; then
    plant_line "variant-multi-hyphen" 0 "UNRUNNABLE|prereq:variant:eigenscript-http-model"
  else
    plant_line "variant-multi-hyphen" 1 "$LAST_PLANT_DETAIL"
  fi
  mk_consumer "$ex_eco" ex_user "bash acceptance"
  printf '%s\n' '#!/bin/sh' 'eigenscript-debug work.eigs' > "$ex_eco/ex_user/acceptance"
  chmod +x "$ex_eco/ex_user/acceptance"
  printf '%s\n' '#!/bin/sh' "printf stale >> \"$stale_dbg\"" 'exit 0' > "$stale_dir/eigenscript-debug"
  chmod +x "$stale_dir/eigenscript-debug"
  : > "$stale_dbg"
  rec="$st_root/var-ex.record"
  if plant_variant_named "$sh" "$ex_eco" "$st_root/stub-ok" "$rec" "$stale_dbg" "$stale_dir/eigenscript-debug" ex_user eigenscript-debug; then
    plant_line "variant-extensionless" 0 "UNRUNNABLE|prereq:variant:eigenscript-debug from extensionless"
  else
    plant_line "variant-extensionless" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- log tail on a FAIL row.
  local lt_eco="$st_root/lt-eco"
  mkdir -p "$lt_eco"
  printf 'fixture\n' > "$lt_eco/.ca_fixture"
  mk_consumer "$lt_eco" log_fail "eigenscript work.eigs; echo UNIQUE_FAIL_MARKER; false"
  rec="$st_root/lt.record"
  if plant_log_tail "$sh" "$lt_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "log-tail" 0 "FAIL row followed by log|log_fail|"
  else
    plant_line "log-tail" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- B2: declared consumer absent.
  local b2_eco="$st_root/b2-eco"
  mkdir -p "$b2_eco"
  printf 'fixture\n' > "$b2_eco/.ca_fixture"
  printf '%s\n' keep missing_one > "$b2_eco/.ca_expected"
  mk_consumer "$b2_eco" keep "eigenscript work.eigs"
  if CA_ECO="$b2_eco" plant_b2_missing_declared "$sh" "$b2_eco" "$st_root/stub-ok"; then
    plant_line "B2 missing-declared" 0 "FAIL naming missing_one in plan and record"
  else
    plant_line "B2 missing-declared" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- B3: 2 consumers, record floor 3 (lexical newest, not mtime).
  local b3_eco="$st_root/b3-eco"
  mkdir -p "$b3_eco/reports/consumer_acceptance"
  printf 'fixture\n' > "$b3_eco/.ca_fixture"
  printf '%s\n' a b > "$b3_eco/.ca_expected"
  mk_consumer "$b3_eco" a "eigenscript work.eigs"
  mk_consumer "$b3_eco" b "eigenscript work.eigs"
  printf '%s\n' 'row|x|v|PASS|0|0' 'row|y|v|PASS|0|0' 'row|z|v|PASS|0|0' \
    > "$b3_eco/reports/consumer_acceptance/2026-09-21-new.record"
  i=1
  while [ "$i" -le 99 ]; do
    printf 'row|old%02d|v|PASS|0|0\n' "$i"
    i=$((i + 1))
  done > "$b3_eco/reports/consumer_acceptance/2020-01-01-old.record"
  touch -d '2026-12-01' "$b3_eco/reports/consumer_acceptance/2020-01-01-old.record" 2>/dev/null \
    || touch -t 202612010000 "$b3_eco/reports/consumer_acceptance/2020-01-01-old.record"
  rec="$st_root/b3.record"
  if plant_b3_record_floor "$sh" "$b3_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "B3 record-floor" 0 "inventory 2 < record floor 3 (lexical, not mtime)"
  else
    plant_line "B3 record-floor" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- noglob: tests/*.eigs stays literal; variant loop also set -f.
  local ng_eco="$st_root/ng-eco" ng_cwd="$st_root/ng-cwd"
  mkdir -p "$ng_eco" "$ng_cwd/tests" "$ng_eco/glob_user/tests"
  printf 'fixture\n' > "$ng_eco/.ca_fixture"
  printf 'x\n' > "$ng_cwd/tests/a.eigs"
  printf 'x\n' > "$ng_eco/glob_user/tests/a.eigs"
  mk_consumer "$ng_eco" glob_user ""
  printf 'eigenscript tests/*.eigs\n' > "$ng_eco/glob_user/.ca_declared"
  mk_consumer "$ng_eco" glob_run "eigenscript *.eigs"
  if plant_noglob "$sh" "$ng_eco" "$ng_cwd" "$st_root/stub-ok"; then
    plant_line "noglob-split" 0 "literal tests/*.eigs, GAP; variant loop no glob"
  else
    plant_line "noglob-split" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- J2: signal between footer-write and rename.
  rec="$st_root/j2.record"
  if plant_j2_pause_rename "$sh" "$j_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "J2 pause-before-rename" 0 "INCOMPLETE exit 2, file and stdout agree, no .rewrite. leftover"
  else
    plant_line "J2 pause-before-rename" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- usage error does not rewrite a committed record.
  rec="$st_root/usage.record"
  if plant_usage_no_candidate "$sh" "$good_eco" "$rec"; then
    plant_line "usage-no-candidate" 0 "exit 2, sha256 unchanged, no .prev"
  else
    plant_line "usage-no-candidate" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- tmp lives next to the record.
  local td="$st_root/recdir"
  mkdir -p "$td"
  rec="$td/record"
  if plant_show_tmp "$sh" "$good_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "tmp-beside-record" 0 "record_tmp_dir equals record directory"
  else
    plant_line "tmp-beside-record" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- first-workflow-wins: tests.yml over bench.yml.
  local wf_eco="$st_root/wf-eco"
  mkdir -p "$wf_eco"
  printf 'fixture\n' > "$wf_eco/.ca_fixture"
  mk_consumer "$wf_eco" pref_user ""
  mkdir -p "$wf_eco/pref_user/.github/workflows"
  printf 'runCmd: eigenscript from-bench.eigs\n' > "$wf_eco/pref_user/.github/workflows/bench.yml"
  printf 'runCmd: eigenscript from-tests.eigs\n' > "$wf_eco/pref_user/.github/workflows/tests.yml"
  if plant_workflow_prefer "$sh" "$wf_eco"; then
    plant_line "workflow-prefer" 0 "tests.yml chosen over bench.yml"
  else
    plant_line "workflow-prefer" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- ambiguous workflows.
  local amb_eco="$st_root/amb-eco"
  mkdir -p "$amb_eco"
  printf 'fixture\n' > "$amb_eco/.ca_fixture"
  mk_consumer "$amb_eco" amb_user ""
  mkdir -p "$amb_eco/amb_user/.github/workflows"
  printf 'runCmd: eigenscript a.eigs\n' > "$amb_eco/amb_user/.github/workflows/a.yml"
  printf 'runCmd: eigenscript b.eigs\n' > "$amb_eco/amb_user/.github/workflows/b.yml"
  rec="$st_root/amb.record"
  if plant_workflow_ambiguous "$sh" "$amb_eco" "$st_root/stub-ok" "$rec"; then
    plant_line "workflow-ambiguous" 0 "UNRUNNABLE|ambiguous-workflow:a.yml,b.yml"
  else
    plant_line "workflow-ambiguous" 1 "$LAST_PLANT_DETAIL"
  fi

  # --- overlay partial retry does not nest.
  local ovp_eco="$st_root/ovp-eco" ovp_stub="$st_root/ovp-cand/src/eigenscript"
  mkdir -p "$ovp_eco" "$st_root/ovp-cand/src/data"
  printf 'fixture\n' > "$ovp_eco/.ca_fixture"
  printf 'x\n' > "$st_root/ovp-cand/src/data/x"
  mk_stub "$ovp_stub" 0
  mk_consumer_block "$ovp_eco" ovp_user \
    'if [ -e "$EIGS_DIR/src/data/data/x" ]; then exit 11; fi' \
    'if [ ! -e "$EIGS_DIR/src/data/x" ]; then exit 12; fi' \
    'eigenscript work.eigs'
  rec="$st_root/ovp.record"
  if plant_overlay_partial "$sh" "$ovp_eco" "$ovp_stub" "$rec"; then
    plant_line "overlay-partial" 0 "src/data/x present, not nested"
  else
    plant_line "overlay-partial" 1 "$LAST_PLANT_DETAIL"
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
      record-busy)      plant_record_busy "$script" "$n_eco_a" "$n_eco_b" "$st_root/stub-ok" "$st_root/stub-bad" "$rec" ;;
      foreign-record)   plant_foreign_record "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      fail-footer)      plant_fail_footer "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      stdout-hup)       plant_footer_signal "$script" "$eco" "$st_root/stub-ok" "$rec" "$extra" ;;
      unexercised)      plant_unexercised "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      tree-consumer)    plant_tree_consumer "$script" "$eco" "$extra" "$rec" ;;
      declared-missing) CA_ECO="$eco" plant_declared_missing "$script" "$eco" ;;
      prereq-missing)   plant_prereq_missing "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      forged-counter)   plant_forged_counter "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      version-only)     plant_version_only "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      swallowed)        plant_swallowed "$script" "$eco" "$st_root/stub-bad" "$rec" ;;
      overlay-write)    plant_overlay_write "$script" "$eco" "$extra" "$rec" ;;
      probe-not-attributed) plant_probe_not_attributed "$script" "$eco" "${extra:-$st_root/stub-gfx}" "$rec" ;;
      interruption)     plant_interruption "$script" "$eco" "$st_root/stub-ok" "$rec" TERM ;;
      bin-routing)      plant_bin_routing "$script" "$eco" "$extra" "$rec" ;;
      gfx-prereq)       plant_gfx_prereq "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      clobber-symlink)  plant_clobber_symlink "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      variant-missing)  plant_variant_missing "$script" "$eco" "$st_root/stub-ok" "$rec" "$stale_log" "$stale_dir/eigenscript-full" ;;
      log-tail)         plant_log_tail "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      missing-declared) CA_ECO="$eco" plant_b2_missing_declared "$script" "$eco" "$st_root/stub-ok" ;;
      noglob-split)     plant_noglob "$script" "$eco" "$ng_cwd" "$st_root/stub-ok" ;;
      record-floor)     plant_b3_record_floor "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      pause-before-rename) plant_j2_pause_rename "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      usage-no-candidate) plant_usage_no_candidate "$script" "$eco" "$rec" ;;
      tmp-beside-record) plant_show_tmp "$script" "$eco" "$st_root/stub-ok" "$rec" ;;
      workflow-prefer)  plant_workflow_prefer "$script" "$eco" ;;
      overlay-partial)  plant_overlay_partial "$script" "$eco" "$extra" "$rec" ;;
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
    local intact=SILENT mutant_st=BROKEN intact_rc=0
    run_named_plant "$plant" "$sh" "$eco" "$rec_i" "$extra"
    intact_rc=$?
    if [ "$intact_rc" -eq 0 ]; then
      intact=FIRES
    elif [ "$intact_rc" -eq 3 ]; then
      # The plant cannot be planted in this environment and said so by
      # name. A skipped row is counted, never a silent OK.
      say "transverse $kind / $plant: SKIP -- $LAST_PLANT_DETAIL"
      ST_SKIP=$((ST_SKIP + 1))
      return
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
    if ! grep -q '^VERDICT:' <<< "$start_out"; then
      say "transverse $kind / $plant: intact=$intact mutant=BROKEN -- mutant plan emitted no VERDICT"
      ST_FAIL=1
      return
    fi
    if run_named_plant "$plant" "$mutant" "$eco" "$rec_m" "$extra"; then
      mutant_st=FIRES
    else
      mutant_st="$(mutant_not_fires_kind)"
    fi
    # Success / side-effect plants: gutting the guard makes the plant
    # condition fail, but the mutant often does not print VERDICT: PASS
    # (UNEXERCISED, FAIL after a refused append, etc.). The transverse
    # is that the plant no longer FIRE.
    case "$plant" in
      tree-consumer|bin-routing|overlay-write|clobber-symlink|overlay-partial|usage-no-candidate|log-tail|variant-missing|record-floor)
        if [ "$intact" = FIRES ] && [ "$mutant_st" != FIRES ]; then
          say "transverse $kind / $plant: intact=FIRES mutant=$mutant_st  OK"
        else
          say "transverse $kind / $plant: intact=$intact mutant=$mutant_st  FAIL (want intact FIRES, mutant not FIRES)"
          ST_FAIL=1
        fi
        return
        ;;
      interruption)
        # finish_incomplete no-op: no stdout VERDICT: INCOMPLETE (plant
        # SILENT) but the record header still says INCOMPLETE, so the
        # mutant is not VERDICT: PASS.
        if [ "$intact" = FIRES ] && [ "$mutant_st" != FIRES ]; then
          say "transverse $kind / $plant: intact=FIRES mutant=SILENT  OK"
        else
          say "transverse $kind / $plant: intact=$intact mutant=$mutant_st  FAIL (want intact FIRES, mutant SILENT)"
          ST_FAIL=1
        fi
        return
        ;;
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

  transverse_one finish-incomplete       interruption     "$d_eco"    t-d
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
  transverse_one record-lock             record-busy      "$n_eco_a"  t-n
  transverse_one append-owned            foreign-record   "$o_eco"    t-o
  transverse_one die-record-flag         fail-footer      "$p_eco"    t-p
  transverse_one stdout-verdict          stdout-hup       "$j_eco"    t-q "$j_shim"
  transverse_one cand-calls              unexercised      "$r_eco"    t-r
  transverse_one eigs-dir                tree-consumer    "$s_eco"    t-s "$s_stub"
  transverse_one declared-file           declared-missing "$t_eco"    t-t
  transverse_one prereq                  prereq-missing   "$u_eco"    t-u
  transverse_one private-log             forged-counter   "$v_eco"    t-v
  transverse_one nontrivial-calls        version-only     "$w_eco"    t-w
  transverse_one swallowed               swallowed        "$x_eco"    t-x
  transverse_one overlay-copy            overlay-write    "$y_eco"    t-y "$y_stub"
  transverse_one probe-not-attributed    probe-not-attributed "$z_idle_eco" t-zidle "$st_root/stub-gfx"
  transverse_one eigenscript-bin         bin-routing      "$aa_eco"   t-aa "$aa_stub"
  transverse_one gfx-prereq              gfx-prereq       "$ab_eco"   t-ab
  transverse_one clobber-no-follow       clobber-symlink  "$ac_eco"   t-ac
  transverse_one variant-mask            variant-missing  "$var_eco"  t-var
  transverse_one log-tail                log-tail         "$lt_eco"   t-lt
  transverse_one expected-floor          missing-declared "$b2_eco"   t-b2
  transverse_one record-floor            record-floor     "$b3_eco"   t-b3
  transverse_one noglob-split            noglob-split     "$ng_eco"   t-ng
  transverse_one pause-before-rename     pause-before-rename "$j_eco" t-j2
  transverse_one usage-before-record     usage-no-candidate "$good_eco" t-use
  transverse_one tmp-beside-record       tmp-beside-record "$good_eco" t-tmp
  transverse_one workflow-prefer         workflow-prefer  "$wf_eco"   t-wf
  transverse_one overlay-retry-rm        overlay-partial  "$ovp_eco"  t-ovp "$ovp_stub"

  if [ "${ST_RUNS:-0}" -gt 0 ] && [ "${ST_UNBOUND:-0}" -eq 0 ]; then
    plant_line "no-unbound-variable" 0 "examined=$ST_RUNS unbound=0"
  else
    plant_line "no-unbound-variable" 1 "examined=${ST_RUNS:-0} unbound=${ST_UNBOUND:-0}"
  fi

  if [ "$ST_FAIL" -ne 0 ]; then
    say "SELF-TEST: FAIL -- one or more plants SILENT or a transverse row failed plants=${ST_PLANTS:-0} skipped=${ST_SKIP:-0}"
    exit 1
  fi
  say "SELF-TEST: PASS -- run-mode plants FIRE and each gutted guard silences its plant plants=${ST_PLANTS:-0} skipped=${ST_SKIP:-0}"
  exit 0
}

case "${1:-plan}" in
  plan)
    resolve_eco
    say "consumer acceptance -- plan"; say ""; inventory ;;
  run)
    shift
    run_mode "$@" ;;
  --self-test)
    selftest ;;
  *) say "usage: $0 [plan|run|--self-test]"; exit 2 ;;
esac

exit "$FAILED"
