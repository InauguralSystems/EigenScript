#!/usr/bin/env bash
# The observer oracle's CI lane (#1764, #1778). Two jobs run it, so the two
# cannot drift: ci.yml's required check `observer oracle (v0.46.0 floor)`
# and the nightly `.github/workflows/observer-oracle.yml`. Run it from a fresh
# checkout in a fresh container (it refuses an anchor that exists before it
# builds one). It:
#   1. fetches the anchor's tag, named by the recipe's TAG= line;
#   2. builds the v0.46.0 anchor with build_anchor.sh. This is the tag's own
#      build, so it runs before the compiler guard, which checks this tree's
#      flags;
#   3. puts tools/cc-guard-bin on PATH (docs/CI.md, [99i]) and builds the
#      candidate (make build);
#   4. runs make observer-oracle, which applies the committed floor. It passes
#      only on the lines that show the floor re-measured on this run's anchor
#      with no verdict lost; every expected value comes from floor.json, the
#      recipe and the anchor's stamp. Only stdout is checked; score.py's
#      errors go to stderr, straight to the log;
#   5. the self-test: plants.py floor-one runs the same floor check through the
#      wrapper observer, with one floor verdict's reading reversed in every
#      arm, and must exit 1 losing exactly that reading's verdicts;
#   6. requires the guard to have seen compiles.
# Exit 0 when every phase passed, 1 otherwise; the failing phase is named.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fail() { echo "::error::observer-oracle lane: $*"; exit 1; }
phase() { printf '\n== observer-oracle lane, at %ss: %s\n' "$SECONDS" "$1"; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/obs_lane.XXXXXX") || fail "no scratch directory"
trap 'rm -rf "$tmp"' EXIT
cache="${XDG_CACHE_HOME:-$HOME/.cache}/eigs-oracle-anchor"

phase "fetch the anchor's tag"
tag=$(sed -n 's/^TAG=//p' tools/observer_oracle/build_anchor.sh)
[ -n "$tag" ] || fail "no TAG= line in tools/observer_oracle/build_anchor.sh"
git rev-parse -q --verify "refs/tags/$tag" > /dev/null \
    || git fetch --no-tags --depth=1 origin "refs/tags/$tag:refs/tags/$tag" \
    || fail "cannot fetch the tag $tag"
git rev-parse "$tag^{commit}" || fail "the tag $tag names no commit"

phase "build the $tag anchor (build_anchor.sh)"
[ ! -e "$cache" ] || fail "$cache exists before the build: the anchor must be built by this run"
bash tools/observer_oracle/build_anchor.sh || fail "build_anchor.sh failed"

phase "build the candidate under the compiler guard (make build)"
PATH="$PWD/tools/cc-guard-bin:$PATH"
CC_GUARD_LOG="$tmp/cc-guard.log"
export PATH CC_GUARD_LOG
: > "$CC_GUARD_LOG"
make build || fail "make build failed"

# TEMPORARY (#1778 demonstration, reverted by the next commit): the floor run
# scores the wrapper observer around the candidate, with one floor verdict's
# reading reversed in every arm. The REQUIRED check must go red.
OBS_WRAP_SPEC=$(python3 -c 'import sys; sys.path.insert(0, "tools/observer_oracle"); import plants; print(plants.one_reversed("tools/observer_oracle")[0])')
printf '#!/bin/sh\nexec python3 %s/tools/observer_oracle/plants.py wrap "$@"\n' "$PWD" > "$tmp/obs_planted"
chmod +x "$tmp/obs_planted"
OBS_WRAP_REAL=$PWD/src/eigenscript OBS_WRAP_MODE=spec OBS_PLANTED=$tmp/obs_planted
export OBS_WRAP_SPEC OBS_WRAP_REAL OBS_WRAP_MODE OBS_PLANTED
echo "planted $OBS_WRAP_SPEC: the floor run scores $OBS_PLANTED"

phase "score the candidate against the committed floor (make observer-oracle)"
rc=0
make observer-oracle | tee "$tmp/oracle.out" || rc=$?
[ "$rc" -eq 0 ] || fail "make observer-oracle exited $rc"
read -r n fmt < <(python3 -c 'import json; f = json.load(open("tools/observer_oracle/floor.json")); print(len(f["verdicts"]), f["format"])') \
    || fail "cannot read tools/observer_oracle/floor.json"
recipe=$(sha256sum tools/observer_oracle/build_anchor.sh | cut -d' ' -f1)
anchor=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["binary"])' "$cache/$recipe/anchor.json") \
    || fail "cannot read the anchor's stamp"
measured="floor: $n verdicts ($fmt), re-measured on the anchor $anchor built by build_anchor.sh ${recipe:0:12}: the list matches; binary sha256 "
[ "$(grep -cF -- "$measured" "$tmp/oracle.out")" -eq 1 ] \
    || fail "no single line '$measured...': the floor was not re-measured on this run's anchor"
[ "$(grep -cx "floor: $n verdicts checked, 0 lost" "$tmp/oracle.out")" -eq 1 ] \
    || fail "no single line 'floor: $n verdicts checked, 0 lost'"
[ "$(grep -cx 'observer oracle exit 0: no gate failed' "$tmp/oracle.out")" -eq 1 ] \
    || fail "no single verdict line 'observer oracle exit 0: no gate failed'"
echo "observer-oracle lane: the floor's $n verdicts were re-measured on this run's $tag anchor and none was lost"

phase "self-test: one floor verdict reversed must turn the floor red (plants.py floor-one)"
rc=0
python3 tools/observer_oracle/plants.py src/eigenscript src/eigenscript --only floor-one | tee "$tmp/plant.out" || rc=$?
[ "$rc" -eq 0 ] || fail "the planted floor loss was NOT caught (plants.py exited $rc)"
[ "$(grep -cx 'plants: 1 examined, 1 red (controls included: green is their red)' "$tmp/plant.out")" -eq 1 ] \
    || fail "no single 'plants: 1 examined, 1 red' summary"

phase "the compiler guard saw the candidate's compiles"
bash tools/cc_guard.sh --report || fail "the compiler guard recorded no compile"
phase "every phase passed"
