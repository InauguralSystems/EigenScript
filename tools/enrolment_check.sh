#!/usr/bin/env bash
# Executable-enrolment gate (#1264, #1880): an entry point nothing runs must FAIL.
#
# PR #1260's tests/test_args_import.sh was run by nothing until a maintainer
# noticed by hand. Every tests/*.sh, tests/*.py, top-level tools entry point,
# tools package, and every self-asserting tests/*.eigs program must be INVOKED — by
# tests/run_all_tests.sh, by a .github/workflows/*.yml step, or by a script
# that is itself invoked (test_dap.py through test_dap.sh) — or be listed in
# tests/enrolment_exemptions.txt as `path | reason`. An exemption for a file
# that is missing or IS invoked is stale and fails.
#
# "Invoked" means the script is what a shell segment RUNS (the argument of
# bash/sh/python3/source/., or the command word, after keywords, VAR=value
# prefixes and launchers): a failure message that names the file is not an
# invocation.  For an asserting .eigs file, invocation specifically means the
# program operand of an "$EIGS"/eigenscript run; a glob in a differential is
# not invocation enrolment.
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
    mkdir -p "$ST/tests/sections" "$ST/tools" "$ST/.github" "$ST/bench"
    cp tests/*.sh tests/*.py "$EXEMPT" "$ST/tests/" && cp tests/sections/*.sh "$ST/tests/sections/" \
        && cp tools/*.sh tools/*.py tools/selftests.txt "$ST/tools/" && cp -R .github/. "$ST/.github/" \
        && cp Makefile "$ST/"
    cp tests/*.eigs "$ST/tests/"
    (cd "$ST" && git init -q && git add .)
    # #2060 is not present on every base branch; keep that known integration
    # gap out of this check's isolated control tree.
    if [ -f "$ST/tests/test_operator_line_parent.eigs" ]; then
        printf '\n"$EIGS" "$TESTS_DIR/test_operator_line_parent.eigs"\n' >> "$ST/tests/sections/15l-binary-operator-line-1425.sh"
    fi
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
    sed -i.bak '/tests\/test_cli.sh | planted/d' "$ST/$EXEMPT" && rm "$ST/$EXEMPT.bak"
    printf 'test_summary of null\n' > "$ST/tests/test_zz_asserting.eigs"
    (cd "$ST" && git add tests/test_zz_asserting.eigs)
    case_ "an asserting .eigs named nowhere is red" 1 "tests/test_zz_asserting.eigs has no suite invocation"
    printf '\n"$EIGS" "$TESTS_DIR/test_zz_asserting.eigs"\n' >> "$ST/tests/sections/99ab-enrolment.sh"
    case_ "the same file named by a section is green" 0 "asserting-test invocation:"
    sed -i.bak '$d' "$ST/tests/sections/99ab-enrolment.sh" && rm "$ST/tests/sections/99ab-enrolment.sh.bak"
    printf '#!/bin/bash\n"$EIGS" "$TESTS_DIR/test_zz_asserting.eigs"\n' > "$ST/tests/test_zz_runner.sh"
    printf '\nbash "$TESTS_DIR/test_zz_runner.sh"\n' >> "$ST/tests/sections/99ab-enrolment.sh"
    (cd "$ST" && git add tests/test_zz_runner.sh)
    case_ "reach through a suite-run runner script counts" 0 "asserting-test invocation:"
    sed -i.bak '$d' "$ST/tests/sections/99ab-enrolment.sh" && rm "$ST/tests/sections/99ab-enrolment.sh.bak"
    rm "$ST/tests/test_zz_runner.sh"; (cd "$ST" && git add -u)
    printf '\nbash tools/jit_diff.sh tests/test_zz_asserting.eigs\n' >> "$ST/tests/sections/99ab-enrolment.sh"
    case_ "differential-only reach is red" 1 "tests/test_zz_asserting.eigs has no suite invocation"
    echo 'tests/test_zz_asserting.eigs | fixture is special' >> "$ST/$EXEMPT"
    case_ "an asserting exemption naming no oracle is red" 1 "must name 'alternate oracle:"
    echo "  checks=$n"
    exit "$bad"
fi

[ -f tests/run_all_tests.sh ] || { echo "test-enrolment: ABORTED: no tests/run_all_tests.sh"; exit 2; }
EDGES=$(mktemp "${TMPDIR:-/tmp}/eigs_enrol.XXXXXX") || exit 2
trap 'rm -f "$EDGES"' EXIT
# Derive the graph before taking its transitive closure.  Keeping extraction
# separate makes every supported edge independently observable in self-tests.
python3 tools/enrolment_edges.py . | sort -u > "$EDGES" || {
    echo "test-enrolment: ABORTED: edge derivation failed"; exit 2;
}
# Commands in the self-test table are reachable through its driver.
awk -F '[|]' '$0 !~ /^#/ {
    n = split($2, a, /[[:space:]]+/)
    for (i = 1; i <= n; i++) if (a[i] ~ /^(tests|tools)\/.*\.(sh|py)$/) print "tools/selftests.sh\t" a[i]
}' tools/selftests.txt >> "$EDGES"
REACHED=$(awk -F'\t' '{ adj[$1] = adj[$1] " " $2 }
    END { q[1] = "tests/run_all_tests.sh"; n = 1
          for (f in adj) if (f ~ /^tests\/sections\/[^\/]+\.sh$/) q[++n] = f
          for (f in adj) if (f ~ /^\.github\//) q[++n] = f
          for (h = 1; h <= n; h++) { m = split(adj[q[h]], t, " ")
              for (j = 1; j <= m; j++) if (!(t[j] in seen)) { seen[t[j]] = 1; q[++n] = t[j]; print t[j] } } }' \
    "$EDGES") || { echo "test-enrolment: ABORTED: reachability scan failed"; exit 2; }

if [ "${1:-}" = "--dump-edges" ]; then cat "$EDGES"; exit 0; fi

rc=0; ok=0; ex=0; total=0
EXEMPTED=$(grep -v '^[[:space:]]*\(#\|$\)' "$EXEMPT" 2>/dev/null || true)
while IFS= read -r row; do
    [ -n "$row" ] || continue
    p=$(printf '%s' "${row%%|*}" | tr -d '[:space:]'); why=$(printf '%s' "${row#*|}" | tr -d '[:space:]')
    if [ "$row" = "${row%%|*}" ] || [ -z "$why" ]; then echo "  FAIL: $EXEMPT exempts '$p' with no reason (path | reason)"; rc=1
    elif [ ! -e "$p" ]; then echo "  FAIL: $EXEMPT exempts $p, which does not exist -- stale, delete the row"; rc=1
    elif grep -qxF "$p" <<< "$REACHED" && [ "${p##*.}" != eigs ]; then echo "  FAIL: $EXEMPT exempts $p, which IS invoked -- stale, delete the row"; rc=1; fi
done <<< "$EXEMPTED"
for f in tests/*.sh tests/*.py tools/*.sh tools/*.py \
    $(find tools -mindepth 2 -maxdepth 2 -type f \( -name '*.sh' -o -name '*.py' \) -printf '%h\n' | sort -u); do
    [ -e "$f" ] || continue; f=${f%/}; total=$((total + 1))
    if grep -qxF "$f" <<< "$REACHED"; then ok=$((ok + 1))
    elif grep -q "^[[:space:]]*$f[[:space:]]*|" <<< "$EXEMPTED"; then ex=$((ex + 1))
    else echo "  FAIL: $f is invoked by nothing -- add a suite section in tests/sections/ (or a workflow step), or list it in $EXEMPT with a reason"; rc=1; fi
done
[ -d .git ] || { echo "test-enrolment: ABORTED: git work tree required for asserting-test population"; exit 2; }
ASSERTING=$(git ls-files 'tests/*.eigs' | while IFS= read -r f; do
    grep -q 'test_summary of' "$f" && printf '%s\n' "$f"
done)
assert_total=0; assert_ok=0; assert_ex=0
while IFS= read -r f; do
    [ -n "$f" ] || continue; assert_total=$((assert_total + 1))
    row=$(printf '%s\n' "$EXEMPTED" | grep "^[[:space:]]*$f[[:space:]]*|" || true)
    if [ -n "$row" ]; then
        case "$row" in
            *'| alternate oracle: '?*) assert_ex=$((assert_ex + 1)) ;;
            *) echo "  FAIL: $EXEMPT exemption for $f must name 'alternate oracle: <what judges it>'"; rc=1 ;;
        esac
    elif grep -qxF "$f" <<< "$REACHED"; then
        assert_ok=$((assert_ok + 1))
    else
        echo "  FAIL: $f has no suite invocation -- run it as the program argument of \"\$EIGS\" in a section or suite-run script"
        rc=1
    fi
done <<< "$ASSERTING"
[ "$assert_total" -gt 0 ] || { echo "test-enrolment: ABORTED: asserting-test population is empty"; exit 2; }
echo "asserting-test invocation: population=$assert_total invoked=$assert_ok alternate-oracle-exempt=$assert_ex"
[ "$total" -gt 0 ] || { echo "test-enrolment: ABORTED: candidate population is empty"; exit 2; }
[ "$rc" -eq 0 ] && echo "PASS: test-enrolment: examined=$total enrolled=$ok exempt=$ex invocation-violations=0"
exit "$rc"
