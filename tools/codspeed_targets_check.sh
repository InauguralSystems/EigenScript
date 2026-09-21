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
#   tools/codspeed_targets_check.sh             # gate
#   tools/codspeed_targets_check.sh --selftest  # every plant must go red
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="${CODSPEED_CFG:-$ROOT/codspeed.yml}"
WF="${CODSPEED_WF:-$ROOT/.github/workflows/codspeed.yml}"

TARGET_COUNT=12                                   # the set is the claim
CONSUMER_IDS="dmg-cpu-instrs dmg-cpu-instrs-vm"   # the rows a proxy cannot replace
CONSUMER_DIR=".codspeed-consumers/DMG"            # what the fetch step populates

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
  grep -qE '^\s*exec:.*'"$CONSUMER_DIR"'/' "$CFG" || { echo "  FAIL: no exec line uses $CONSUMER_DIR/"; fail=1; }
  # the pin is a full SHA, never a branch or tag
  ref=$(grep -oE 'DMG_REF:\s*\S+' "$WF" | head -1 | awk '{print $2}')
  [ -n "$ref" ] || { echo "  FAIL: no DMG_REF in the workflow"; fail=1; }
  if [ -n "$ref" ] && ! printf '%s' "$ref" | grep -qE '^[0-9a-f]{40}$'; then
    echo "  FAIL: DMG_REF '$ref' is not a 40-hex commit SHA (a branch is not a pin)"; fail=1
  fi
  grep -q "$CONSUMER_DIR" "$WF" || { echo "  FAIL: the workflow does not populate $CONSUMER_DIR"; fail=1; }
  return $fail
}

if [ "${1:-}" = "--selftest" ]; then
  W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
  red=0; total=0
  plant() {  # name, then a command that writes the planted files into $W
    local name="$1"; shift; total=$((total+1))
    cp "$CFG" "$W/codspeed.yml"; cp "$WF" "$W/codspeed-wf.yml"; "$@"
    if CODSPEED_CFG="$W/codspeed.yml" CODSPEED_WF="$W/codspeed-wf.yml" "$0" >/dev/null 2>&1; then
      echo "  SELFTEST FAILED: plant '$name' passed the gate"
    else
      echo "  ok: plant '$name' is red"; red=$((red+1))
    fi
  }
  plant "consumer rows deleted"   sed -i '/id: dmg-cpu-instrs/d' "$W/codspeed.yml"
  plant "one target dropped"      sed -i '0,/^\s*- name: "scalar_loop"$/{/^\s*- name: "scalar_loop"$/d}' "$W/codspeed.yml"
  plant "pin is a branch name"    sed -i -E 's/DMG_REF:\s*[0-9a-f]{40}/DMG_REF: master/' "$W/codspeed-wf.yml"
  plant "exec points elsewhere"   sed -i 's#\.codspeed-consumers/DMG/#../DMG/#g' "$W/codspeed.yml"
  # the weaker shape that actually slipped: only the SCRIPT path moved
  plant "script path elsewhere"   sed -i 's#\.codspeed-consumers/DMG/dmg.eigs#../DMG/dmg.eigs#' "$W/codspeed.yml"
  # control: the live files must pass, or every plant above is vacuous
  total=$((total+1))
  if "$0" >/dev/null 2>&1; then echo "  ok: live config passes (control)"; red=$((red+1)); else echo "  SELFTEST FAILED: live config is red"; fi
  [ "$red" = "$total" ] && { echo "SELFTEST OK: $red/$total"; exit 0; }
  echo "SELFTEST FAILED: $red/$total"; exit 1
fi

if check; then echo "codspeed targets: $TARGET_COUNT declared == found; consumer rows present; DMG pinned by SHA"; exit 0; fi
echo "codspeed_targets_check: FAIL (the lane would measure less than it claims)"; exit 1
