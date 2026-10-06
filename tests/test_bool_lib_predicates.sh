#!/usr/bin/env bash
# test_bool_lib_predicates.sh -- #1637: every lib/ predicate returns a bool on
# every path. This is measured by running the predicates, not by reading the
# source.
#
# Population: the lib functions `eigenscript --api` lists whose name is
# predicate-shaped (is_*, has_*, can_*, *_has, *_empty, *_equal,
# *s_intersect, point_in_*, polygon_is_*, any, all, ...; PRED below).
#
# Each predicate is called on a fixed battery of argument tuples drawn from
# POOL: numbers, strings, lists, points, polygons, dicts, null, bools and a
# lambda. The extra cases in tests/bool_lib_predicates_cases.txt are added.
# Every call runs in its own try:
#   - a call that RAISES is not an answer and is ignored;
#   - a call that RETURNS must return a `bool`.
#
# Exits 0 iff all of these hold:
#   - no predicate returned a non-bool;
#   - examined == declared > 0;
#   - every predicate answered at least once;
#   - each predicate answered both true and false. The exceptions are the
#     one_sided rows, and each needs a reason.
#
# The result type is printed on a line of its own (`@T:<type>`), so a string
# answer containing spaces or newlines is still counted as a non-bool.
# usage: test_bool_lib_predicates.sh [BINARY] [--table]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="${1:-$ROOT/src/eigenscript}"
case "$BIN" in --table) BIN="$ROOT/src/eigenscript" ;; esac
case "$BIN" in /*) ;; *) BIN="$(pwd)/$BIN" ;; esac
TABLE=0; for a in "$@"; do [ "$a" = --table ] && TABLE=1; done
CASES="$HERE/bool_lib_predicates_cases.txt"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs_bool_libpred.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
if command -v timeout >/dev/null 2>&1; then TMO="timeout 60"
elif command -v gtimeout >/dev/null 2>&1; then TMO="gtimeout 60"
else TMO="env"; fi

PRED='^((is_|has_|can_)[a-z0-9_]*|[a-z0-9_]*_has|[a-z0-9_]*_empty|[a-z0-9_]*_equal|[a-z0-9_]*s_intersect|point_in_[a-z0-9_]*|polygon_is_[a-z0-9_]*|any|all|collinear|on_segment|in_range|eq_near|get_flag|is_one_of|utf8_validate|sm_can_send|sm_is|json_has|map_has|set_has|is_subset|is_superset|set_equal|git_worktree_clean|check_openai)$'
"$BIN" --api > "$WORK/api.txt" || { echo "BOOL_LIB_PREDICATES: FAIL (--api)"; exit 1; }
# module|name|arity
awk -v PRED="$PRED" '$1 == "lib" {
    sig = $0; sub(/^lib /, "", sig)
    if (!match(sig, /^[a-z0-9_]+[.][a-z0-9_]+[(]/)) next
    mn = substr(sig, 1, RLENGTH - 1); split(mn, p, ".")
    params = substr(sig, RLENGTH + 1); sub(/[)].*/, "", params)
    k = 0; if (params ~ /[^ ]/) k = split(params, junk, ",")
    if (p[2] ~ PRED || mn == "functional.complement") print p[1] "|" p[2] "|" k
}' "$WORK/api.txt" > "$WORK/fns.txt"
DECLARED=$(grep -c . "$WORK/fns.txt")

# The battery: tuple i of arity k takes POOL[(i + 3j) mod n] for j < k, plus
# the constant tuple POOL[i] repeated k times.
POOL_FILE="$WORK/pool.txt"
cat > "$POOL_FILE" <<'EOF'
0
1
-1
2.5
10
""
"abc"
"a@b.co"
"http://x.y/z"
"123"
[]
[1, 2, 3]
[3, 1, 2]
[0, 0]
[1, 1]
[2, 2]
[[0, 0], [4, 0], [0, 4]]
[[0, 0], [4, 0], [4, 4], [0, 4]]
{}
{"a": 1}
null
true
false
(x) => x > 1
EOF

emit_call() {   # name arity "a;;b;;c" -> one try block
    local name=$1 k=$2 args=$3 call
    if [ "$k" -ge 2 ]; then call="$name of [$(printf '%s' "$args" | sed 's/;;/, /g')]"
    elif [ "$k" -eq 1 ]; then call="$name of ($args)"
    else call="$name of null"; fi
    printf 'try:\n    __r is %s\n    print of ("@T:" + (type of __r))\n    if (type of __r) == "bool":\n        print of ("@B:" + (str of __r))\ncatch __e:\n    print of "@raised"\n' "$call"
}

examined=0; failures=0; unmeasured=0
: > "$WORK/table.txt"
while IFS='|' read -r mod name k; do
    examined=$((examined + 1))
    skipwhy=$(awk -F'|' -v n="$name" '$1 == "skip" && $2 == n {print $3; exit}' "$CASES")
    if [ -n "$skipwhy" ]; then echo "$mod.$name: skipped ($skipwhy)" >> "$WORK/table.txt"; continue; fi
    prog="$WORK/p.eigs"
    printf 'load_file of "%s/lib/%s.eigs"\n' "$ROOT" "$mod" > "$prog"
    awk -F'|' -v q="$mod.$name" '$1 == "case" && $2 == q && $3 != "" {print $3}' "$CASES" |
        sed 's/\\n/\
/g' >> "$prog"
    if [ "$k" -eq 0 ]; then emit_call "$name" 0 "" >> "$prog"
    else
        awk -v k="$k" '{ pool[n++] = $0 } END {
            for (i = 0; i < n; i++) {
                t = ""; c = ""
                for (j = 0; j < k; j++) {
                    t = t (j ? ";;" : "") pool[(i + j * 3) % n]
                    c = c (j ? ";;" : "") pool[i]
                }
                print t; print c
            } }' "$POOL_FILE" > "$WORK/tuples.txt"
        while IFS= read -r t; do emit_call "$name" "$k" "$t" >> "$prog"; done < "$WORK/tuples.txt"
    fi
    awk -F'|' -v q="$mod.$name" '$1 == "case" && $2 == q {print $4}' "$CASES" > "$WORK/extra.txt"
    while IFS= read -r t; do emit_call "$name" "$k" "$t" >> "$prog"; done < "$WORK/extra.txt"
    printf 'print of "@END"\n' >> "$prog"
    out=$(cd "$WORK" && env -u DISPLAY -u WAYLAND_DISPLAY SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
          EIGS_STRICT=1 bash -c 'ulimit -v 1500000; exec $0 "$1" "$2"' "$TMO" "$BIN" "$prog" </dev/null 2>/dev/null)
    if ! grep -q '^@END$' <<< "$out"; then
        echo "  FAIL: $mod.$name: probe program did not complete"; failures=$((failures + 1)); continue
    fi
    nt=$(grep -c '^@B:true$' <<< "$out"); nf=$(grep -c '^@B:false$' <<< "$out")
    nr=$(grep -c '^@raised$' <<< "$out")
    types=$(grep '^@T:' <<< "$out" | sort | uniq -c | awk '{printf "%s%s=%s", (NR > 1 ? "," : ""), substr($2, 4), $1}')
    echo "$mod.$name: types={$types} true=$nt false=$nf raised=$nr" >> "$WORK/table.txt"
    nonbool=$(grep '^@T:' <<< "$out" | grep -vc '^@T:bool$')
    if [ "$nonbool" -gt 0 ]; then
        echo "  FAIL: $mod.$name: returned a non-bool ($types)"; failures=$((failures + 1))
    elif [ -z "$types" ]; then
        echo "  FAIL: $mod.$name: every battery call raised; nothing measured"; unmeasured=$((unmeasured + 1))
    elif [ "$nt" -eq 0 ] || [ "$nf" -eq 0 ]; then
        if ! awk -F'|' -v q="$mod.$name" '$1 == "one_sided" && $2 == q && $3 != "" {f = 1} END {exit !f}' "$CASES"; then
            [ "$nt" -eq 0 ] && only=false || only=true
            echo "  FAIL: $mod.$name: answered only $only; add a case for the other answer"
            failures=$((failures + 1))
        fi
    fi
done < "$WORK/fns.txt"
[ "$TABLE" = 1 ] && cat "$WORK/table.txt"
ok=0
[ "$examined" -eq "$DECLARED" ] && [ "$DECLARED" -gt 0 ] && [ "$failures" -eq 0 ] && [ "$unmeasured" -eq 0 ] && ok=1
echo "BOOL_LIB_PREDICATES: examined=$examined/$DECLARED nonbool=$failures unmeasured=$unmeasured $([ "$ok" = 1 ] && echo PASS || echo FAIL)"
# The runner's #988 rule wants a PASS:/FAIL: marker from a test_* child.
[ "$ok" = 1 ] && echo "  PASS: every lib predicate answers with a bool" || echo "  FAIL: lib predicates (see above)"
[ "$ok" = 1 ]
