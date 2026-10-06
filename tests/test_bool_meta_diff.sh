#!/usr/bin/env bash
# test_bool_meta_diff.sh -- #1637: the self-hosted interpreter (lib/eigen.eigs
# `eigen_run`) agrees with the VM on every bool-producing form: comparisons,
# `not`, the literals, the predicate builtins and the observer predicates (bare
# and named). It must also agree on the raises (bool vs number, a bool index).
# Each snippet in tests/bool_meta_snippets.txt runs as its own VM program and
# through `eigen_run`; both print `[type of v, v]` or `raised <kind>`, and the
# two lines must be identical. Exit 0 iff every snippet agreed and ran, and
# snippets == declared > 0.
# usage: test_bool_meta_diff.sh [BINARY]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="${1:-$ROOT/src/eigenscript}"
case "$BIN" in /*) ;; *) BIN="$(pwd)/$BIN" ;; esac
SNIPS="$HERE/bool_meta_snippets.txt"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs_bool_meta.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
if command -v timeout >/dev/null 2>&1; then TMO="timeout 30"
elif command -v gtimeout >/dev/null 2>&1; then TMO="gtimeout 30"
else TMO="env"; fi

wrap() {   # body lines on stdin -> a try block printing [type of __v, __v]
    printf 'try:\n'
    sed 's/^/    /'
    printf '    print of [type of __v, __v]\ncatch __e:\n    print of ("raised " + __e.kind)\n'
}
run() { (cd "$ROOT" && $TMO "$BIN" "$1" </dev/null 2>/dev/null); }

declared=$(grep -v '^#' "$SNIPS" | grep -c .)
ran=0; bad=0
while IFS='|' read -r setup expr; do
    case "$setup" in \#*) continue ;; esac
    [ -z "$setup$expr" ] && continue
    code=$(printf '%s' "$setup" | sed 's/\\n/\
/g')
    [ -n "$code" ] && code="$code
"
    code="$code$expr"
    { [ -n "$setup" ] && printf '%s\n' "$code" | sed '$d'; printf '__v is (%s)\n' "$expr"; } | wrap > "$WORK/vm.eigs"
    lit=$(printf '%s' "$code" | awk 'BEGIN { ORS = "" } { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); if (NR > 1) print "\\n"; print }')
    { printf 'load_file of "lib/eigen.eigs"\n'; printf '__v is eigen_run of "%s"\n' "$lit" | wrap; } > "$WORK/meta.eigs"
    ov=$(run "$WORK/vm.eigs"); rv=$?
    om=$(run "$WORK/meta.eigs"); rm_=$?
    ran=$((ran + 1))
    if [ "$rv" != 0 ] || [ "$rm_" != 0 ] || [ -z "$ov" ] || [ "$ov" != "$om" ]; then
        echo "  FAIL: '$expr' (setup '$setup'): VM='$ov' (rc $rv)  eigen_run='$om' (rc $rm_)"
        bad=$((bad + 1))
    fi
done < "$SNIPS"
ok=0
[ "$ran" -eq "$declared" ] && [ "$declared" -gt 0 ] && [ "$bad" -eq 0 ] && ok=1
echo "BOOL_META_DIFF: snippets=$ran/$declared disagree=$bad $([ "$ok" = 1 ] && echo PASS || echo FAIL)"
# The runner's #988 rule wants a PASS:/FAIL: marker from a test_* child.
[ "$ok" = 1 ] && echo "  PASS: eigen_run agrees with the VM on every snippet" || echo "  FAIL: eigen_run vs VM (see above)"
[ "$ok" = 1 ]
