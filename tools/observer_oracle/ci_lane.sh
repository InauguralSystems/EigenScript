#!/usr/bin/env bash
# The observer oracle's CI lane (#1764, #1778, #1777). ci.yml's required check
# `observer oracle (floor)` runs it on every code change. It is safe to run from
# any clone: the anchor goes into a scratch cache, never the user's. It:
#   1. fetches the anchor's tag (the recipe's TAG=) when the clone lacks it,
#      shallowly only into a shallow clone;
#   2. builds the v0.46.0 anchor with `make observer-anchor`, which runs the
#      recipe under env -i, so neither this shell nor the compiler guard reaches
#      the tag's build; on failure, the build log's tail goes to stderr;
#   3. puts tools/cc-guard-bin on PATH (docs/CI.md, [99i]) and builds the
#      candidate (make build);
#   4. runs score.py on the candidate against the committed floor, directly, so
#      its exit code is the verdict: 1 is a lost or split verdict (the gate
#      working), 2 a harness error. Every floor verdict must then have been
#      compared;
#   5. requires the guard to have seen the candidate's compiles.
# The proof that the floor can still fail is not re-run here: it is the
# tools/selftests.txt row `plants.py --selftest`, which runs when
# tools/observer_oracle/ changes (docs/PRINCIPLES.md section 5).
# Exit 0 when every phase passed, 1 otherwise; the failing phase is named.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fail() { echo "::error::observer-oracle lane: $*"; exit 1; }
phase() { printf '\n== observer-oracle lane, at %ss: %s\n' "$SECONDS" "$1"; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/obs_lane.XXXXXX") || fail "no scratch directory"
trap 'rm -rf "$tmp"' EXIT
export XDG_CACHE_HOME="$tmp/cache"

phase "the anchor's tag"
tag=$(sed -n 's/^TAG=//p' tools/observer_oracle/build_anchor.sh)
[ -n "$tag" ] || fail "no TAG= line in tools/observer_oracle/build_anchor.sh"
if ! git rev-parse -q --verify "refs/tags/$tag" > /dev/null; then
    if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
        git fetch --no-tags --depth=1 origin "refs/tags/$tag:refs/tags/$tag" || fail "cannot fetch the tag $tag"
    else
        git fetch --no-tags origin "refs/tags/$tag:refs/tags/$tag" || fail "cannot fetch the tag $tag"
    fi
fi

phase "build the $tag anchor (make observer-anchor)"
recipe=$(sha256sum tools/observer_oracle/build_anchor.sh | cut -d' ' -f1)
if ! make --no-print-directory observer-anchor; then
    log="$XDG_CACHE_HOME/eigs-oracle-anchor/$recipe.log"
    [ ! -f "$log" ] || tail -n 50 "$log" >&2
    fail "the anchor build failed (build_anchor.sh's message, and its build log's tail if it got that far, are above)"
fi

phase "build the candidate under the compiler guard (make build)"
PATH="$PWD/tools/cc-guard-bin:$PATH"
CC_GUARD_LOG="$tmp/cc-guard.log"
export PATH CC_GUARD_LOG
: > "$CC_GUARD_LOG"
make build || fail "make build failed"

phase "score the candidate against the committed floor (score.py --floor)"
rc=0
python3 tools/observer_oracle/score.py src/eigenscript --floor tools/observer_oracle/floor.json | tee "$tmp/oracle.out" || rc=$?
case "$rc" in
    0) ;;
    1) fail "score.py exit 1: a verdict was lost or split between arms (the FLOOR VIOLATION, FINDING or CAPABILITY WRONG lines above). The gate is working: fix the change, or fix a wrong label through derive.py/certify.py and re-measure the floor" ;;
    *) fail "score.py exit $rc: a harness error (the OBSERVER_ORACLE_ERROR line above), not a verdict" ;;
esac
n=$(python3 -c 'import json; print(len(json.load(open("tools/observer_oracle/floor.json"))["verdicts"]))') \
    || fail "cannot read tools/observer_oracle/floor.json"
[ "$(grep -cx "floor: $n verdicts checked, 0 lost" "$tmp/oracle.out")" -eq 1 ] \
    || fail "score.py did not report all $n floor verdicts compared"

phase "the compiler guard saw the candidate's compiles"
bash tools/cc_guard.sh --report || fail "the compiler guard recorded no compile"
phase "every phase passed"
