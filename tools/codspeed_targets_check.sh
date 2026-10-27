#!/usr/bin/env bash
# codspeed_targets_check.sh -- the CodSpeed lane's target set is a CLAIM, and
# this pins it. Runs in .github/workflows/codspeed.yml before the action.
#
# What it stops (mechanical-gates section 97): "the lane measured LESS and
# printed green." Bought 2026-09-21: the lane's first ten targets were the
# Ir-gate workloads plus the JIT's OWN benches; on those the JIT removes 48%
# of instructions, on the real DMG 11% (#1178). A real consumer row fixed
# that -- and nothing would notice if the row were deleted, if its pin were
# edited to a branch name (a moving consumer puts ITS changes in OUR trend
# line), or if the row pointed at a path the fetch step does not populate.
# Each of those is a plant below; found == declared, never ">= 1".
#
# The same file pins the lane's UNIT (#2002). The Value is modeled cycles, and
# the runner (plus the valgrind fork it installs) decides that; the action's
# default runner moves with every dependabot bump. So `runner-version` must be
# an exact release pin, and the guard step (tools/codspeed_unit_guard.py) must
# exist, read the CodSpeed step's run-id, and be able to fail the job -- else
# the unit could change again and the lane stay green. The guard's own row must
# be a declared, plain (no `env` wrapper) target.
#
#   tools/codspeed_targets_check.sh             # gate
#   tools/codspeed_targets_check.sh --selftest  # every plant must go red
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="${CODSPEED_CFG:-$ROOT/codspeed.yml}"
WF="${CODSPEED_WF:-$ROOT/.github/workflows/codspeed.yml}"
GUARD="${CODSPEED_GUARD:-$ROOT/tools/codspeed_unit_guard.py}"

TARGET_COUNT=13                                   # the set is the claim
CONSUMER_IDS="dmg-cpu-instrs dmg-cpu-instrs-vm"   # the rows a proxy cannot replace
CONSUMER_DIR=".codspeed-consumers/DMG"            # what the fetch step populates

# The guard step, verbatim (comments and blank lines aside). A step that can be skipped (`if: false`, a push-only `if:`),
# neutered (`shell:`, `continue-on-error:`) or unwired (the run-id) is the same fault as no step at all.
GUARD_STEP_PIN=$(cat <<'PIN'
      - name: Guard the lane's unit (tools/codspeed_unit_guard.py)
        if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository
        env:
          CODSPEED_RUN_ID: ${{ steps.codspeed.outputs.run-id }}
        run: python3 tools/codspeed_unit_guard.py
PIN
)

# The lines of the workflow step whose "- name:" line contains $2, comments and blank lines removed.
step_block() {
  awk -v pat="$2" '
    /^      - name:/ { p = (index($0, pat) > 0) }
    p && !/^[[:space:]]*#/ && !/^[[:space:]]*$/ { print }' "$1"
}

check() {
  local fail=0 n ids ref
  n=$(grep -cE '^\s*-\s*name:' "$CFG")
  [ "$n" = "$TARGET_COUNT" ] || { echo "  FAIL: $n targets declared, TARGET_COUNT pins $TARGET_COUNT"; fail=1; }
  for id in $CONSUMER_IDS; do
    grep -qE "^\s*id:\s*$id\s*$" "$CFG" || { echo "  FAIL: consumer target id '$id' missing from codspeed.yml"; fail=1; }
  done
  # every DMG path on an exec line must live under the dir the fetch step
  # fills: strip the sanctioned prefix and no "DMG/" may remain. (A first
  # version only asked that SOME argument used the dir; a script path of
  # ../DMG/dmg.eigs beside a sanctioned ROM path passed -- selftest plant 4.)
  if grep -E '^\s*exec:.*DMG/' "$CFG" | sed "s#$CONSUMER_DIR/##g" | grep -q 'DMG/'; then
    echo "  FAIL: an exec line reaches DMG outside $CONSUMER_DIR/ (a local checkout is not the pin)"; fail=1
  fi
  # A sanctioned textual prefix is not sufficient when a following `..`
  # component can escape it during filesystem path resolution.
  if grep -E '^\s*exec:.*DMG/' "$CFG" | grep -qE '(^|[[:space:]/])\.\.([[:space:]/]|$)'; then
    echo "  FAIL: a DMG exec line contains a '..' path component (it can escape $CONSUMER_DIR/)"; fail=1
  fi
  grep -qE '^\s*exec:.*'"$CONSUMER_DIR"'/' "$CFG" || { echo "  FAIL: no exec line uses $CONSUMER_DIR/"; fail=1; }
  # the pin is a full SHA, never a branch or tag
  ref=$(grep -oE 'DMG_REF:\s*\S+' "$WF" | head -1 | awk '{print $2}')
  [ -n "$ref" ] || { echo "  FAIL: no DMG_REF in the workflow"; fail=1; }
  if [ -n "$ref" ] && ! printf '%s' "$ref" | grep -qE '^[0-9a-f]{40}$'; then
    echo "  FAIL: DMG_REF '$ref' is not a 40-hex commit SHA (a branch is not a pin)"; fail=1
  fi
  grep -q "$CONSUMER_DIR" "$WF" || { echo "  FAIL: the workflow does not populate $CONSUMER_DIR"; fail=1; }
  # the unit: an exact runner pin, inside the CodSpeed step itself (a pin in another step's env pins nothing) ...
  blk=$(step_block "$WF" "Run codspeed.yml targets under CPU simulation")
  [ -n "$blk" ] || { echo "  FAIL: no 'Run codspeed.yml targets under CPU simulation' step in the workflow"; fail=1; }
  pin=$(printf '%s\n' "$blk" | grep -oE '^\s*runner-version:\s*\S+' | head -1 | awk '{print $2}')
  [ -n "$pin" ] || { echo "  FAIL: no runner-version pin in the CodSpeed step (the action's default runner moves with every bump and decides the unit)"; fail=1; }
  if [ -n "$pin" ] && ! printf '%s' "$pin" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "  FAIL: runner-version '$pin' is not an exact X.Y.Z release (latest, a branch, a rev or a prerelease is not a pin)"; fail=1
  fi
  printf '%s\n' "$blk" | grep -qE '^\s*id:\s*codspeed\s*$' || { echo "  FAIL: the CodSpeed step has no 'id: codspeed' (the guard reads its run-id output)"; fail=1; }
  printf '%s\n' "$blk" | grep -qE '^\s*mode:\s*simulation\s*$' || { echo "  FAIL: the CodSpeed step is not 'mode: simulation'"; fail=1; }
  printf '%s\n' "$blk" | grep -qE '^\s*cycle-estimation:\s*false\s*$' || { echo "  FAIL: the CodSpeed step does not say 'cycle-estimation: false' (the registered unit is the one without a cycle table)"; fail=1; }
  # ... and the guard that re-derives it on every run: the step is pinned verbatim, and nothing can wave it through
  [ "$(step_block "$WF" "Guard the lane's unit")" = "$GUARD_STEP_PIN" ] || { echo "  FAIL: the guard step is missing or differs from the pinned step (if:, env:, run:, shell: and the run-id wiring are all part of it)"; fail=1; }
  grep -q 'continue-on-error' "$WF" && { echo "  FAIL: the lane uses continue-on-error (a red unit guard would stay green)"; fail=1; }
  gt=$(sed -n 's/^GUARD_TARGET = "\([^"]*\)".*/\1/p' "$GUARD" | head -1)
  if [ -z "$gt" ]; then echo "  FAIL: no GUARD_TARGET in $GUARD"; fail=1
  else
    row=$(grep -A3 -E "^\s*-\s*name:\s*\"$gt\"\s*\$" "$CFG" | grep -E '^\s*exec:' | head -1)
    [ -n "$row" ] || { echo "  FAIL: the unit guard's row '$gt' is not a declared target with an exec line"; fail=1; }
    # the guard matches the runner's profile by the row's command: it must be exactly `./src/eigenscript <path>` (no env wrapper,
    # quotes or trailing comment) and no other row may end up running the same command (a twin shares the profile's cmd: line)
    if ! printf '%s' "$row" | grep -qE '^\s*exec:\s*\./src/eigenscript [A-Za-z0-9_./-]+\s*$'; then
      echo "  FAIL: the unit guard's row '$gt' must run exactly './src/eigenscript <path>' (found: $row)"; fail=1
    else
      cmd=$(printf '%s' "$row" | sed -E 's/^\s*exec:\s*//; s/\s+$//')
      twins=$(grep -E '^\s*exec:' "$CFG" | sed -E 's/^\s*exec:\s*//; s/\s+$//; s/^env( [A-Za-z_][A-Za-z0-9_]*=[^ ]*)* //' | grep -cFx -- "$cmd")
      [ "$twins" = 1 ] || { echo "  FAIL: $twins rows run the unit guard row's command ($cmd): its profile would be ambiguous"; fail=1; }
    fi
  fi
  return $fail
}

if [ "${1:-}" = "--selftest" ]; then
  W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
  red=0; total=0
  plant() {  # name, then a command that writes the planted files into $W
    local name="$1"; shift; total=$((total+1))
    cp "$CFG" "$W/codspeed.yml"; cp "$WF" "$W/codspeed-wf.yml"; "$@"
    if CODSPEED_CFG="$W/codspeed.yml" CODSPEED_WF="$W/codspeed-wf.yml" "$0" >"$W/out.txt" 2>&1; then
      echo "  SELFTEST FAILED: plant '$name' passed the gate"
    else
      # the first reason the gate gave, so that a plant that is red for the wrong reason is visible
      echo "  ok: plant '$name' is red: $(grep -m1 'FAIL:' "$W/out.txt" | cut -c9-130)"; red=$((red+1))
    fi
  }
  plant "consumer rows deleted"   sed -i '/id: dmg-cpu-instrs/d' "$W/codspeed.yml"
  plant "one target dropped"      sed -i '0,/^\s*- name: "scalar_loop"$/{/^\s*- name: "scalar_loop"$/d}' "$W/codspeed.yml"
  plant "pin is a branch name"    sed -i -E 's/DMG_REF:\s*[0-9a-f]{40}/DMG_REF: master/' "$W/codspeed-wf.yml"
  plant "exec points elsewhere"   sed -i 's#\.codspeed-consumers/DMG/#../DMG/#g' "$W/codspeed.yml"
  # the weaker shape that actually slipped: only the SCRIPT path moved
  plant "script path elsewhere"   sed -i 's#\.codspeed-consumers/DMG/dmg.eigs#../DMG/dmg.eigs#' "$W/codspeed.yml"
  plant "consumer path traverses" sed -i 's#\.codspeed-consumers/DMG/dmg.eigs#.codspeed-consumers/DMG/../../tests/bench_dmg_shape.eigs#g' "$W/codspeed.yml"
  # the unit pin and its guard (#2002): each is a way for the unit to move and the lane to stay green
  plant "runner pin removed"      sed -i '/^\s*runner-version:/d' "$W/codspeed-wf.yml"
  plant "runner pin is latest"    sed -i -E 's/^(\s*runner-version:).*/\1 latest/' "$W/codspeed-wf.yml"
  plant "runner pin moved to another step" sed -i -e '/^\s*runner-version:/d' -e 's/^\(\s*\)- uses: actions\/checkout\(.*\)$/&\n\1  env:\n\1    runner-version: 5.5.0/' "$W/codspeed-wf.yml"
  plant "cycle estimation switched on" sed -i -E 's/^(\s*cycle-estimation:).*/\1 true/' "$W/codspeed-wf.yml"
  plant "CodSpeed step id lost"   sed -i '/^\s*id: codspeed\s*$/d' "$W/codspeed-wf.yml"
  plant "guard step removed"      sed -i '/codspeed_unit_guard/d' "$W/codspeed-wf.yml"
  plant "guard cannot fail"       sed -i -E 's#^(\s*)(run: python3 tools/codspeed_unit_guard\.py)#\1continue-on-error: true\n\1\2#' "$W/codspeed-wf.yml"
  plant "guard not given run-id"  sed -i 's/steps\.codspeed\.outputs\.run-id/steps.codspeed.outputs.nothing/' "$W/codspeed-wf.yml"
  plant "guard skipped (if: false)" sed -i -E "s/^(\s*)if: github\.event_name != 'pull_request'.*/\1if: false/" "$W/codspeed-wf.yml"
  plant "guard runs on push only" sed -i -E "s/^(\s*)if: github\.event_name != 'pull_request'.*/\1if: github.event_name == 'push'/" "$W/codspeed-wf.yml"
  plant "guard shell neutered"    sed -i -E "s#^(\s*)(run: python3 tools/codspeed_unit_guard\.py)#\1shell: bash -c 'exit 0' {0}\n\1\2#" "$W/codspeed-wf.yml"
  plant "guard row renamed"       sed -i -E 's/^(\s*-\s*name:\s*)"observed_loop"\s*$/\1"observed_loop_renamed"/' "$W/codspeed.yml"
  plant "guard row env-wrapped"   sed -i -E '/name: "observed_loop"\s*$/,/exec:/{s#exec: \./#exec: env X=1 ./#}' "$W/codspeed.yml"
  plant "guard row has a comment" sed -i -E '/name: "observed_loop"\s*$/,/exec:/{s#(exec: .*)$#\1  \# note#}' "$W/codspeed.yml"
  plant "guard row has a twin"    sed -i 's#exec: env EIGS_JIT_OFF=1 ./src/eigenscript bench/scalar_loop.eigs#exec: env EIGS_JIT_OFF=1 ./src/eigenscript bench/observed_loop.eigs#' "$W/codspeed.yml"
  # control: the live files must pass, or every plant above is vacuous
  total=$((total+1))
  if "$0" >/dev/null 2>&1; then echo "  ok: live config passes (control)"; red=$((red+1)); else echo "  SELFTEST FAILED: live config is red"; fi
  [ "$red" = "$total" ] && { echo "SELFTEST OK: $red/$total"; exit 0; }
  echo "SELFTEST FAILED: $red/$total"; exit 1
fi

if check; then echo "codspeed targets: $TARGET_COUNT declared == found; consumer rows present; DMG pinned by SHA; runner pinned; unit guard wired"; exit 0; fi
echo "codspeed_targets_check: FAIL (the lane would measure less than it claims)"; exit 1
