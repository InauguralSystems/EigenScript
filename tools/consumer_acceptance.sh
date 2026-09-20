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
#   tools/consumer_acceptance.sh run [BINARY]    run it, serially
#   tools/consumer_acceptance.sh --self-test     plant a fault, prove it fires
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ECO="$(cd "$HERE/.." && pwd)"
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

inventory() {
  local r pin cmd n=0 gaps=0
  for d in "$ECO"/*/; do
    r="$(basename "$d")"
    [ "$r" = "EigenScript" ] && continue
    pin="$(pin_of "$r")"
    if [ -z "$pin" ]; then
      # Not a consumer. Only complain if it is also unexplained AND looks live.
      [ -n "${EXCLUDED[$r]:-}" ] || [ ! -d "$d/.git" ] || say "  note   $r: pins nothing, not excluded -- not gated"
      continue
    fi
    if [ -n "${EXCLUDED[$r]:-}" ]; then
      say "  skip   $r  ($pin) -- ${EXCLUDED[$r]}"
      continue
    fi
    n=$((n+1))
    if cmd="$(accept_cmd_of "$r")"; then
      : # derived from the consumer's own CI
    elif [ -n "${DECLARED[$r]:-}" ]; then
      cmd="${DECLARED[$r]}"
      say "  gate   $r  ($pin)  [declared -- CI has no runCmd to derive]"
      say "         $ $cmd"
      continue
    fi
    if [ -n "${cmd:-}" ]; then
      local lines; lines="$(printf '%s' "$cmd" | wc -l)"
      say "  gate   $r  ($pin)"
      if [ "$lines" -gt 0 ]; then
        say "         $ $(printf '%s' "$cmd" | head -1 | cut -c1-100) ... (+$lines lines)"
      else
        say "         $ $(printf '%s' "$cmd" | cut -c1-110)"
      fi
    else
      say "  GAP    $r  ($pin) -- pins the runtime but no acceptance command could be derived"
      gaps=$((gaps+1))
    fi
  done
  say ""
  if [ "$n" -eq 0 ]; then
    say "VERDICT: FAIL -- the inventory examined ZERO consumers"; FAILED=1; return
  fi
  if [ "$gaps" -gt 0 ]; then
    say "VERDICT: FAIL -- $gaps of $n consumers have no derivable acceptance command"; FAILED=1; return
  fi
  say "VERDICT: PASS -- $n consumers, every one with a derived acceptance command"
}

case "${1:-plan}" in
  plan) say "consumer acceptance -- plan"; say ""; inventory ;;
  run)  say "run mode is not implemented yet: it executes the plan serially against a"
        say "candidate build and records per-consumer results. The plan above is M1's"
        say "first half -- the declared, coverage-checked inventory."; exit 2 ;;
  --self-test)
        # The fault that matters: a live consumer that pins the runtime but
        # whose acceptance command cannot be found must FAIL, not vanish.
        tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
        mkdir -p "$tmpd/.devcontainer" "$tmpd/.git"
        printf 'ARG EIGS_REF=v0.43.0\n' > "$tmpd/.devcontainer/Dockerfile"
        ln -s "$tmpd" "$ECO/zz-planted-consumer" 2>/dev/null
        out="$("$0" plan 2>&1)"; rm -f "$ECO/zz-planted-consumer"
        if printf '%s' "$out" | grep -q "GAP    zz-planted-consumer"; then
          say "SELF-TEST: PASS -- an ungated consumer fails the plan"; exit 0
        fi
        say "SELF-TEST: FAIL -- a planted ungated consumer did not fail the plan"
        printf '%s\n' "$out" | tail -5; exit 1 ;;
  *) say "usage: $0 [plan|run|--self-test]"; exit 2 ;;
esac

exit "$FAILED"
