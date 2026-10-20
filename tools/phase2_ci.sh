#!/usr/bin/env bash
# tools/phase2_ci.sh <tag-binary> <main-binary> <branch-binary>
# #1758 Phase 2's CI lane (.github/workflows/phase2.yml): the MAP rows that have
# landed (tools/phase2_check.sh, design 9.2) and the stdlib int differential
# (tools/phase2_lib_diff.sh, design 9.5). The workflow builds the three
# binaries: the v0.46.0 anchor (make observer-anchor), origin/main and this
# commit.
#
# --through is DERIVED, so no round constant needs bumping. A round has landed
# when every one of its MAP rows has its file in tests/phase2/rows (read with
# phase2_check.py's own MAP parser), and --through is the last round, in plan
# order, before the first round with rows that has not. A file may land ahead
# of its round (a target row: N14.json-path-int-exact's R1.6 file came with
# R1.3), so a file alone is not a landing; a partly landed round is printed
# and checked once it is complete. A round with no rows of its own (R1.8,
# R2.1) never selects itself: its gates are its own builder's to run.
#
# Each tool must exit 0 AND print its own PASS line, whole: a tool that died
# after its last successful command never prints it.
set -u
[ $# -eq 3 ] || { echo "usage: tools/phase2_ci.sh <tag-binary> <main-binary> <branch-binary>"; exit 2; }
bins=()
for b in "$@"; do case "$b" in /*) bins+=("$b") ;; *) bins+=("$PWD/$b") ;; esac; done
cd "$(dirname "$0")/.." || exit 2
tmp=$(mktemp "${TMPDIR:-/tmp}/phase2-ci.XXXXXX") || exit 2
trap 'rm -f "$tmp"' EXIT
python3 -W error - > "$tmp" <<'EOF' || { cat "$tmp"; echo "phase2-ci: FAIL: could not derive --through"; exit 1; }
import os, sys
sys.path.insert(0, 'tools')
import phase2_check as p
rows, bad = p.parse_map(os.path.join(p.ROOT, 'tests/phase2/MAP.md'))
if bad:
    print('phase2-ci: the MAP does not parse: ' + '; '.join(bad))
    sys.exit(1)
have = {}
for r in rows:
    if r['kind'] == 'row' and r['round']:
        landed = bool(p.row_file(os.path.join(p.ROOT, 'tests/phase2/rows'), r['id']))
        have.setdefault(r['round'], []).append((r['id'], landed))
through, done = None, True
for rd in p.ROUNDS:
    if not have.get(rd):
        continue
    got = [i for i, ok in have[rd] if ok]
    if done and len(got) == len(have[rd]):
        through = rd
        continue
    done = False
    if got:
        print('phase2-ci: %s has %d of %d row files (%s): not checked until all land'
              % (rd, len(got), len(have[rd]), ' '.join(got)))
if through is None:
    print('phase2-ci: no round has all of its row files')
    sys.exit(1)
print('THROUGH ' + through)
EOF
grep -v '^THROUGH ' "$tmp"
through=$(sed -n 's/^THROUGH //p' "$tmp")
echo "phase2-ci: through=$through (the last round whose MAP rows all have files)"
fails=""
verdict() {   # verdict NAME RC OUTPUT VERDICT-ERE: the tool's output; rc 0 and its verdict line, once
    printf '%s\n' "$3"
    [ "$2" -eq 0 ] && [ "$(grep -cE "$4" <<< "$3")" -eq 1 ] || fails="$fails $1(rc=$2)"
}
out=$(bash tools/phase2_check.sh --through "$through" "${bins[0]}" "${bins[2]}" 2>&1); rc=$?
verdict phase2-check "$rc" "$out" '^phase2-check: PASS$'
out=$(bash tools/phase2_lib_diff.sh "${bins[1]}" "${bins[2]}" 2>&1); rc=$?
verdict phase2-lib-diff "$rc" "$out" '^phase2-lib-diff: listed_functions=[0-9]+ undeclared=0 stale=0 PASS$'
if [ -n "$fails" ]; then
    echo "phase2-ci: FAIL:$fails"
    exit 1
fi
echo "phase2-ci: PASS (through=$through)"
