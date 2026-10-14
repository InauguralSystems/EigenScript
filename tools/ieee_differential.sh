#!/bin/bash
# #1746 Phase 1 EXPERIMENT: the guarded-vs-IEEE corpus differential.
#
#   bash tools/ieee_differential.sh <release-bin> <ieee-bin> <report-dir>
#
# Population: every TOP-LEVEL tests/*.eigs tracked by git, minus gfx/server
# programs (a call to a gfx_/ui_/http_/net_/serve builtin, or a lib/ui load).
# Asserts examined + excluded == tracked > 0. Each program runs once per build
# (cwd src/, stdin /dev/null, `timeout`); stdout, stderr and rc are compared.
# A program that differs is re-run on the release build: if release disagrees
# with ITSELF it is NONDET (no attribution possible), never a finding.
# Programs that time out under BOTH builds are listed as TIMEOUT (no evidence).
#
# Every differing program must have exactly one row in
# tools/ieee_differential_classes.txt (`<file> <class> <reason>`, class a|b|c),
# and every row must name a program that differs: a missing row or a stale
# row is a FAIL (both directions). Then two named external rows:
#   dynamics/tests/bifurcation_oracle.eigs (its own test_bifurcation.sh gate)
#   EigenLua math.huge (1e308 * 10) printed through bin/eigenlua.
# Verdict line: `IEEE_DIFF: examined=<n> differ=<d> nondet=<k> timeout=<t> classified=<c> FAIL=<f>`.
set -u
REL="${1:?release binary}"; IEEE="${2:?ieee binary}"; OUT="${3:?report dir}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ECO="${IEEE_DIFF_ECOSYSTEM:-$(cd "$ROOT/.." && pwd)}"
CLASSES="$ROOT/tools/ieee_differential_classes.txt"
TMO="${IEEE_DIFF_TIMEOUT:-60}"
mkdir -p "$OUT/rel" "$OUT/ieee" "$OUT/rel2" || exit 2
FAILS=0
bad() { echo "FAIL $*"; FAILS=$((FAILS+1)); }
for b in "$REL" "$IEEE"; do [ -x "$b" ] || { echo "FAIL setup: not executable: $b"; exit 2; }; done
# The stdlib resolves from the executable's own directory (<exe>/../lib), so
# each build runs from a copy beside a lib -> $ROOT/lib link; cwd is src/, as
# in tests/run_all_tests.sh.
mkdir -p "$OUT/bin_rel" "$OUT/bin_ieee" && ln -sfn "$ROOT/lib" "$OUT/lib" \
  && cp "$REL" "$OUT/bin_rel/eigenscript" && cp "$IEEE" "$OUT/bin_ieee/eigenscript" || exit 2
REL="$OUT/bin_rel/eigenscript"; IEEE="$OUT/bin_ieee/eigenscript"
cd "$ROOT/src" || exit 2
git -C "$ROOT" ls-files 'tests/*.eigs' | awk -F/ 'NF==2{print $2}' | sort > "$OUT/tracked.txt"
GFX_RE='(gfx_[a-z_]+|ui_[a-z_]+|http_[a-z_]+|net_[a-z_]+|serve[a-z_]*) of|load_file of .*lib/ui'
: > "$OUT/population.txt"; : > "$OUT/excluded.txt"
while read -r f; do
    if grep -qE "$GFX_RE" "../tests/$f"; then echo "$f" >> "$OUT/excluded.txt"; else echo "$f" >> "$OUT/population.txt"; fi
done < "$OUT/tracked.txt"
TRACKED=$(wc -l < "$OUT/tracked.txt"); POP=$(wc -l < "$OUT/population.txt"); EXC=$(wc -l < "$OUT/excluded.txt")
echo "population: tracked=$TRACKED examined=$POP excluded=$EXC (gfx/server: $(tr '\n' ' ' < "$OUT/excluded.txt"))"
[ "$TRACKED" -gt 0 ] && [ $((POP + EXC)) -eq "$TRACKED" ] || { echo "FAIL population: $POP + $EXC != $TRACKED"; exit 1; }

runone() {   # <bin> <dir> <file>
    timeout "$TMO" "$1" "../tests/$3" < /dev/null > "$2/$3.out" 2> "$2/$3.err"
    echo $? > "$2/$3.rc"
}
same() {     # <dirA> <dirB> <file>
    cmp -s "$1/$3.out" "$2/$3.out" && cmp -s "$1/$3.err" "$2/$3.err" && cmp -s "$1/$3.rc" "$2/$3.rc"
}
: > "$OUT/differ.txt"; : > "$OUT/nondet.txt"; : > "$OUT/timeout.txt"
n=0
while read -r f; do
    n=$((n+1))
    runone "$REL" "$OUT/rel" "$f"
    runone "$IEEE" "$OUT/ieee" "$f"
    rr=$(cat "$OUT/rel/$f.rc"); ri=$(cat "$OUT/ieee/$f.rc")
    if [ "$rr" = 124 ] && [ "$ri" = 124 ]; then echo "$f" >> "$OUT/timeout.txt"; continue; fi
    same "$OUT/rel" "$OUT/ieee" "$f" && continue
    runone "$REL" "$OUT/rel2" "$f"
    if ! same "$OUT/rel" "$OUT/rel2" "$f"; then echo "$f" >> "$OUT/nondet.txt"; continue; fi
    streams=""
    cmp -s "$OUT/rel/$f.out" "$OUT/ieee/$f.out" || streams="${streams}stdout,"
    cmp -s "$OUT/rel/$f.err" "$OUT/ieee/$f.err" || streams="${streams}stderr,"
    [ "$rr" = "$ri" ] || streams="${streams}rc($rr->$ri),"
    echo "$f ${streams%,}" >> "$OUT/differ.txt"
    { echo "=== $f [${streams%,}]"
      diff <(cat "$OUT/rel/$f.out" "$OUT/rel/$f.err") <(cat "$OUT/ieee/$f.out" "$OUT/ieee/$f.err") | head -12
    } >> "$OUT/diffs.txt"
done < "$OUT/population.txt"
[ "$n" -eq "$POP" ] || bad "examined $n of $POP"
DIFF=$(wc -l < "$OUT/differ.txt"); ND=$(wc -l < "$OUT/nondet.txt"); TO=$(wc -l < "$OUT/timeout.txt")

# Classification, both directions.
CL=0
while read -r f rest; do
    row=$(awk -v f="$f" '$1==f' "$CLASSES" 2>/dev/null)
    case "$(echo "$row" | wc -l)$(echo "$row" | awk '{print $2}')" in
        1a|1b|1c) CL=$((CL+1)); echo "DIFF $f [$rest] class=$(echo "$row" | cut -d' ' -f2-)" ;;
        *) bad "unclassified difference: $f [$rest]" ;;
    esac
done < "$OUT/differ.txt"
while read -r f cls reason; do
    case "$f" in ''|'#'*) continue ;; esac
    grep -q "^$f " "$OUT/differ.txt" || bad "stale class row (program does not differ): $f"
done < "$CLASSES"
while read -r f; do echo "NONDET $f (release differs from itself)"; done < "$OUT/nondet.txt"
while read -r f; do echo "TIMEOUT $f (both builds hit ${TMO}s)"; done < "$OUT/timeout.txt"

# Named external rows.
DYN="$ECO/dynamics"
if [ -f "$DYN/tests/bifurcation_oracle.eigs" ]; then
    for side in rel ieee; do
        b=$REL; [ $side = ieee ] && b=$IEEE
        ( cd "$DYN" && timeout 300 "$b" tests/bifurcation_oracle.eigs ) > "$OUT/dyn_$side.out" 2>&1; echo $? > "$OUT/dyn_$side.rc"
        ( cd "$DYN" && EIGENSCRIPT="$b" timeout 600 bash tests/test_bifurcation.sh ) > "$OUT/dyn_gate_$side.out" 2>&1; echo $? > "$OUT/dyn_gate_$side.rc"
    done
    if cmp -s "$OUT/dyn_rel.out" "$OUT/dyn_ieee.out"; then dsame=identical; else dsame="differs ($(diff "$OUT/dyn_rel.out" "$OUT/dyn_ieee.out" | grep -c '^[<>]') lines)"; fi
    echo "EXTERNAL dynamics/bifurcation_oracle: output release-vs-ieee $dsame; rc rel=$(cat "$OUT/dyn_rel.rc") ieee=$(cat "$OUT/dyn_ieee.rc"); test_bifurcation.sh rc rel=$(cat "$OUT/dyn_gate_rel.rc") ieee=$(cat "$OUT/dyn_gate_ieee.rc") (last: $(tail -1 "$OUT/dyn_gate_ieee.out"))"
    [ "$(cat "$OUT/dyn_gate_ieee.rc")" = 0 ] || bad "dynamics test_bifurcation.sh is red under ieee"
else bad "dynamics checkout absent at $DYN (named row cannot run)"; fi
LUA="$ECO/EigenLua"
if [ -x "$LUA/bin/eigenlua" ]; then
    printf 'print(math.huge, -math.huge, math.huge > 1e308, math.huge == math.huge * 2)\n' > "$OUT/huge.lua"
    for side in rel ieee; do
        b=$REL; [ $side = ieee ] && b=$IEEE
        EIGENSCRIPT="$b" timeout 120 "$LUA/bin/eigenlua" "$OUT/huge.lua" > "$OUT/lua_$side.out" 2> "$OUT/lua_$side.err"; echo $? > "$OUT/lua_$side.rc"
    done
    echo "EXTERNAL EigenLua math.huge: release='$(cat "$OUT/lua_rel.out")' rc=$(cat "$OUT/lua_rel.rc"); ieee='$(cat "$OUT/lua_ieee.out")' rc=$(cat "$OUT/lua_ieee.rc")"
    grep -q '^inf' "$OUT/lua_ieee.out" || bad "EigenLua math.huge is not inf under ieee"
else bad "EigenLua checkout absent at $LUA (named row cannot run)"; fi

echo "IEEE_DIFF: examined=$POP differ=$DIFF nondet=$ND timeout=$TO classified=$CL FAIL=$FAILS"
[ "$FAILS" = 0 ]
