#!/usr/bin/env bash
# Test-enrolment gate (#1264): a test script nothing runs must FAIL.
#
# PR #1260's tests/test_args_import.sh was run by nothing until a maintainer
# noticed by hand. Every tests/*.sh and tests/*.py must be INVOKED — by
# tests/run_all_tests.sh, by a .github/workflows/*.yml step, or by a script
# that is itself invoked (test_dap.py through test_dap.sh) — or be listed in
# tests/enrolment_exemptions.txt as `path | reason`. An exemption for a file
# that is missing or IS invoked is stale and fails.
#
# "Invoked" means the script is what a shell segment RUNS (the argument of
# bash/sh/python3/source/., or the command word, after keywords, VAR=value
# prefixes and launchers): a failure message that names the file is not an
# invocation. tests/*.eigs are out of scope — they are consumed through
# imports, globbed directories, mutant harnesses and python drivers, so
# "invoked" has no single syntactic meaning for them.
#
# Usage: tools/enrolment_check.sh [--selftest]    exit 0 pass, 1 fail, 2 no instrument
# ENROL_ROOT overrides the repository root (the selftest points it at a copy).
set -u
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "${ENROL_ROOT:-$(dirname "$0")/..}" || exit 2
EXEMPT=tests/enrolment_exemptions.txt

if [ "${1:-}" = "--selftest" ]; then
    ST=$(mktemp -d "${TMPDIR:-/tmp}/eigs_enrol_st.XXXXXX") || exit 2
    trap 'rm -rf "$ST"' EXIT
    mkdir -p "$ST/tests" "$ST/tools" "$ST/.github"
    cp tests/*.sh tests/*.py "$EXEMPT" "$ST/tests/" && cp tools/*.sh tools/selftests.txt "$ST/tools/" && cp -R .github/workflows "$ST/.github/"
    n=0; bad=0
    case_() {   # case_ <name> <want-rc> <want-substring>
        local out rc; n=$((n + 1))
        out=$(ENROL_ROOT="$ST" bash "$SELF" 2>&1); rc=$?
        if [ "$rc" -eq "$2" ] && grep -qF -- "$3" <<< "$out"; then echo "  selftest ok: $1"
        else echo "  SELFTEST FAIL: $1 (rc=$rc, want $2 + '$3')"; printf '%s\n' "$out" | sed 's/^/      /'; bad=1; fi
    }
    case_ "control: the unmodified tree passes" 0 "PASS: test-enrolment"
    printf '#!/bin/bash\necho "PASS: x"\n' > "$ST/tests/test_zz_plant.sh"
    case_ "an uninvoked tests/test_zz_plant.sh is red and named" 1 "tests/test_zz_plant.sh is invoked by nothing"
    rm "$ST/tests/test_zz_plant.sh"
    # test_child_exit.sh runs a temp "$WORK/test_clean.sh": same basename, other dir.
    grep -q 'bash "$WORK/test_clean.sh"' tests/test_child_exit.sh || { echo "  SELFTEST BROKEN: the temp-path shape is gone from test_child_exit.sh"; bad=1; }
    printf '#!/bin/bash\n' > "$ST/tests/test_clean.sh"
    case_ "a same-named temp path elsewhere does not enrol tests/test_clean.sh" 1 "tests/test_clean.sh is invoked by nothing"
    rm "$ST/tests/test_clean.sh"
    echo 'tests/test_cli.sh | planted: test_cli.sh IS invoked' >> "$ST/$EXEMPT"
    case_ "an exemption for an invoked script is stale: red" 1 "exempts tests/test_cli.sh, which IS invoked"
    echo "  checks=$n"
    exit "$bad"
fi

[ -f tests/run_all_tests.sh ] || { echo "test-enrolment: ABORTED: no tests/run_all_tests.sh"; exit 2; }
KNOWN=" $(cd tests && ls | tr '\n' ' ') "
EDGES=$(mktemp "${TMPDIR:-/tmp}/eigs_enrol.XXXXXX") || exit 2
trap 'rm -f "$EDGES"' EXIT
# Every edge "src<TAB>tests/target" out of the roots and all tests/tools shell
# scripts, in one awk pass; the closure below keeps only reachable sources.
awk -v known="$KNOWN" '
function strip(s,   c) {
    for (c = 1; c; ) {
        c = sub(/^[[:space:]]+/, "", s) + sub(/^(-[[:space:]]+)?run:[[:space:]]*/, "", s) \
          + sub(/^(if|then|elif|else|do|while|until|time|!|\{)[[:space:]]+/, "", s) \
          + sub(/^[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|\047[^\047]*\047|[^[:space:]]*)[[:space:]]+/, "", s) \
          + sub(/^(env|command|exec|nohup|sudo|xvfb-run)([[:space:]]+-[A-Za-z-]+)*[[:space:]]+/, "", s) \
          + sub(/^timeout([[:space:]]+-[^[:space:]]+)*[[:space:]]+[0-9.]+[smhd]?[[:space:]]+/, "", s)
        if (s ~ /^"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?[[:space:]]+(bash|sh|python3?)[[:space:]]/)
            c += sub(/^[^[:space:]]+[[:space:]]+/, "", s)   # $EIGS_TMO bash x.sh
    }
    return s
}
{
    line = $0
    sub(/(^|[[:space:]])#.*$/, "", line)                  # a comment starts a word
    gsub(/\$\((dirname|cd) [^)]*\)/, "$DIR", line)        # a directory, not a command
    gsub(/\$\(/, "\n", line); gsub(/\)/, "\001\n", line)  # \001 marks a segment cut by ")"
    gsub(/[(;`]|&&|\|\||\|/, "\n", line)
    n = split(line, seg, "\n")
    for (i = 1; i <= n; i++) {
        s = strip(seg[i]); closed = (s ~ /\001/); gsub(/\001/, "", s)
        if (s !~ /\.(sh|py)/) continue
        w = s; sub(/[[:space:]].*/, "", w); gsub(/["\047]/, "", w)
        if (w ~ /^(bash|sh|dash|python3?|source|\.)$/) {
            s = substr(s, length(w) + 1); sub(/^[[:space:]]+/, "", s)
            while (s ~ /^-[A-Za-z]+[[:space:]]/) sub(/^-[A-Za-z]+[[:space:]]+/, "", s)
            w = s; sub(/[[:space:]].*/, "", w); gsub(/["\047]/, "", w)
        } else if (closed && s !~ /[[:space:]]/) continue   # `x.sh)` is a case pattern
        b = w; sub(/.*\//, "", b); d = w; sub(/\/?[^\/]*$/, "", d)
        # Only a path that RESOLVES under tests/ counts: tests/x, ../tests/x, $TESTS_DIR/x,
        # the dir of a tests/ script, or a bare name after `cd tests` — never $WORK/x (#1264 r2).
        intests = (d ~ /(^|\/)tests$|TESTS_DIR\}?$/) || (d == "$DIR" && FILENAME ~ /^tests\//) || (d == "" && FILENAME !~ /^tools\//)
        if (w !~ /tools\// && w ~ /\.(sh|py)$/ && intests && index(known, " " b " ")) print FILENAME "\ttests/" b
        else if (w ~ /tools\/[^\/]*\.sh$/) print FILENAME "\ttools/" b
    }
}' tests/run_all_tests.sh .github/workflows/*.yml tests/*.sh tools/*.sh | sort -u > "$EDGES"
# Commands in the self-test table are reachable through its driver.
awk -F '[|]' '$0 !~ /^#/ {
    n = split($2, a, /[[:space:]]+/)
    for (i = 1; i <= n; i++) if (a[i] ~ /^tests\/.*\.(sh|py)$/) print "tools/selftests.sh\t" a[i]
}' tools/selftests.txt >> "$EDGES"
REACHED=$(awk -F'\t' '{ adj[$1] = adj[$1] " " $2 }
    END { q[1] = "tests/run_all_tests.sh"; n = 1
          for (f in adj) if (f ~ /^\.github\//) q[++n] = f
          for (h = 1; h <= n; h++) { m = split(adj[q[h]], t, " ")
              for (j = 1; j <= m; j++) if (!(t[j] in seen)) { seen[t[j]] = 1; q[++n] = t[j]; print t[j] } } }' \
    "$EDGES")

rc=0; ok=0; ex=0; total=0
EXEMPTED=$(grep -v '^[[:space:]]*\(#\|$\)' "$EXEMPT" 2>/dev/null || true)
while IFS= read -r row; do
    [ -n "$row" ] || continue
    p=$(printf '%s' "${row%%|*}" | tr -d '[:space:]'); why=$(printf '%s' "${row#*|}" | tr -d '[:space:]')
    if [ "$row" = "${row%%|*}" ] || [ -z "$why" ]; then echo "  FAIL: $EXEMPT exempts '$p' with no reason (path | reason)"; rc=1
    elif [ ! -f "$p" ]; then echo "  FAIL: $EXEMPT exempts $p, which does not exist -- stale, delete the row"; rc=1
    elif grep -qxF "$p" <<< "$REACHED"; then echo "  FAIL: $EXEMPT exempts $p, which IS invoked -- stale, delete the row"; rc=1; fi
done <<< "$EXEMPTED"
for f in tests/*.sh tests/*.py; do
    [ -f "$f" ] || continue; total=$((total + 1))
    if grep -qxF "$f" <<< "$REACHED"; then ok=$((ok + 1))
    elif grep -q "^[[:space:]]*$f[[:space:]]*|" <<< "$EXEMPTED"; then ex=$((ex + 1))
    else echo "  FAIL: $f is invoked by nothing -- add a suite section in tests/run_all_tests.sh (or a workflow step), or list it in $EXEMPT with a reason"; rc=1; fi
done
[ "$total" -gt 0 ] || { echo "test-enrolment: ABORTED: tests/*.sh + tests/*.py is empty"; exit 2; }
[ "$rc" -eq 0 ] && echo "PASS: test-enrolment: examined=$total enrolled=$ok exempt=$ex"
exit "$rc"
