#!/usr/bin/env bash
# Test-enrolment gate (#1264): a test script nothing runs must FAIL.
#
# BOUGHT: PR #1260 added tests/test_args_import.sh, a correct regression test,
# and nothing in the tree ran it. It was enrolled as suite section [59a] only
# because a maintainer noticed by hand after a ~45-minute CI run -- while a
# STYLE rule over the same file failed loudly and named its fix. Two more
# scripts sat outside tests/run_all_tests.sh (test_amalgamation.sh and
# test_ci_portability.sh); those two are run by .github/workflows/ci.yml
# directly, so they ARE enrolled -- which is why "in the suite" is the wrong
# question and "invoked by something CI runs" is the right one.
#
# THE RULE. Every tests/*.sh and tests/*.py must be one of:
#   * ENROLLED -- reachable by INVOCATION from a root: tests/run_all_tests.sh
#     or any .github/workflows/*.yml, directly or through a chain of scripts
#     (tests/* or tools/*) that are themselves reachable. test_dap.py counts
#     because the enrolled test_dap.sh runs it; aux_binary.sh counts because
#     an enrolled script sources it.
#   * EXEMPT -- listed in tests/enrolment_exemptions.txt as `path | reason`.
#     An exemption is a waiver (mechanical-gates §3): it must name a file that
#     exists, carry a reason, and be NEEDED -- an exemption for a file that is
#     in fact enrolled is STALE and fails, so the list can only shrink toward
#     what is true.
#
# WHAT "INVOKED" MEANS -- and why a mention is not enough. A section's own
# failure message usually names its script ("FAIL: ... -- run
# tests/test_args_import.sh"). Delete the invocation and that echo still
# mentions the file, so a name-grep keeps it "enrolled" forever. The matcher
# therefore reads SHELL SEGMENTS (split on ; && || | $( ` and parentheses) and
# requires the script to be the thing a segment RUNS: the argument of
# bash/sh/python3/source/`.`, or the command word itself, after stripping
# keywords (if/then/!/...), VAR=value prefixes and launchers (env, timeout N,
# $EIGS_TMO, xvfb-run, sudo). An echo/printf/grep/cat segment never enrols.
# The selftest plants exactly that: remove [59a]'s invocation, keep its echo.
#
# WHY NOT tests/*.eigs. Measured 2026-09-23: 288 .eigs files, consumed through
# at least six mechanisms -- the runner's `./eigenscript tests/x.eigs`, globbed
# directories, `import` from other .eigs, the *_mt mutant harnesses (tools/),
# python drivers, and bench/. "Invoked" has no single syntactic key there, and
# a name-mention test is the loose matcher this file refuses above. The
# defect #1260 exhibited is a DRIVER script nobody runs; a .eigs a driver
# forgot is caught by that driver's own pinned check count. Recorded as the
# residual, not solved.
#
# Usage:
#   tools/test_enrolment_check.sh               audit the tree (exit 0 / 1)
#   tools/test_enrolment_check.sh --selftest    plant each fault in a copy
#   tools/test_enrolment_check.sh --invocations FILE...
#       print, one per line, the repo-relative tests/ or tools/ script each
#       FILE invokes (the same matcher the audit uses). tools/precheck.sh
#       derives "the tools CI runs" from this, so the two cannot disagree
#       about what an invocation is.
# Exit: 0 = pass, 1 = a verdict (unenrolled test / bad exemption),
#       2 = the instrument could not measure (no roots, empty population).
#
# ENROL_ROOT overrides the repository root (the selftest points it at a copy).

set -u
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="${ENROL_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || { echo "test-enrolment: ABORTED: cannot cd to $ROOT" >&2; exit 2; }
EXEMPT_FILE="tests/enrolment_exemptions.txt"

# ---------------------------------------------------------------------------
# The invocation matcher. Reads one file, prints the raw script WORD of every
# segment that runs a .sh or .py. Resolution to a path happens in resolve().
# ---------------------------------------------------------------------------
invoked_words() {   # invoked_words <file>...  -> "file<TAB>word" lines
    awk '
    function strip_prefixes(s,   changed) {
        changed = 1
        while (changed) {
            changed = 0
            if (sub(/^[[:space:]]+/, "", s)) changed = 1
            # YAML step keys in front of a one-line run.
            if (sub(/^-[[:space:]]+/, "", s)) changed = 1
            if (sub(/^run:[[:space:]]*/, "", s)) changed = 1
            # Shell keywords and grouping.
            if (sub(/^(if|then|elif|else|do|while|until|time|!|\{)[[:space:]]+/, "", s)) changed = 1
            # VAR=value prefixes (value may be quoted).
            if (sub(/^[A-Za-z_][A-Za-z0-9_]*=("[^"]*"|\047[^\047]*\047|[^[:space:]]*)[[:space:]]+/, "", s)) changed = 1
            # Launchers that exec what follows.
            if (sub(/^(env|command|exec|nohup|sudo|xvfb-run)([[:space:]]+-[A-Za-z-]+)*[[:space:]]+/, "", s)) changed = 1
            if (sub(/^timeout([[:space:]]+-[A-Za-z-]+(=[^[:space:]]+)?)*[[:space:]]+[0-9.]+[smhd]?[[:space:]]+/, "", s)) changed = 1
            # A variable used as a launcher ($EIGS_TMO bash x.sh) -- only when
            # something follows it; a lone "$X" is not judged.
            if (s ~ /^"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?[[:space:]]+[^[:space:]]/ && s !~ /^"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?[[:space:]]+-/) {
                sub(/^"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?[[:space:]]+/, "", s); changed = 1
            }
        }
        return s
    }
    {
        line = $0
        # Comments: a # that begins a word. (A bare [[:space:]]*# would also
        # eat ${x#y} and "(#988)" in the middle of a real command.)
        sub(/(^|[[:space:]])#.*$/, "", line)
        if (line ~ /^[[:space:]]*$/) next
        # $(dirname "$0") and friends name a DIRECTORY; fold them to a token
        # so splitting on "$(" does not leave "/x.sh" looking like a command.
        gsub(/\$\(dirname[^)]*\)/, "$DIR", line)
        gsub(/\$\(cd [^)]*\)/, "$DIR", line)
        gsub(/\$\(/, "\n", line)
        # A segment cut by ")" is marked, so a bare `x.sh)` -- a CASE PATTERN,
        # not a command -- is told apart from `$(bash x.sh)` below.
        gsub(/\)/, "\001\n", line)
        gsub(/[(;`]|&&|\|\||\|/, "\n", line)
        n = split(line, seg, "\n")
        for (i = 1; i <= n; i++) {
            s = strip_prefixes(seg[i])
            closed = (s ~ /\001[[:space:]]*$/)
            gsub(/\001/, "", s)
            if (s !~ /\.(sh|py)/) continue
            first = s; sub(/[[:space:]].*$/, "", first)
            gsub(/["\047]/, "", first)
            if (closed && s ~ /^[^[:space:]]+[[:space:]]*$/ && first !~ /^(bash|sh|dash|python3|python|source|\.)$/) continue
            if (first ~ /^(bash|sh|dash|python3|python|source|\.)$/) {
                rest = s; sub(/^[^[:space:]]+[[:space:]]*/, "", rest)
                # skip interpreter flags (bash -x, python3 -u)
                while (rest ~ /^-[A-Za-z]+[[:space:]]+/) sub(/^-[A-Za-z]+[[:space:]]+/, "", rest)
                word = rest; sub(/[[:space:]].*$/, "", word)
            } else {
                word = first
            }
            gsub(/["\047]/, "", word)
            if (word ~ /\.(sh|py)$/) print FILENAME "\t" word
        }
    }' "$@"
}

# Map each script word to a repo path under tests/ or tools/ (dropped if
# neither holds it). One awk over a listing made once -- a per-word subshell
# made the audit cost seconds.
KNOWN_TESTS="$( (cd tests 2>/dev/null && ls) | tr '\n' ' ')"
KNOWN_TOOLS="$( (cd tools 2>/dev/null && ls) | tr '\n' ' ')"
resolve_words() {
    awk -v tests=" $KNOWN_TESTS " -v tools=" $KNOWN_TOOLS " '
    {
        src = $0; sub(/\t.*/, "", src)
        w = $0; sub(/^[^\t]*\t/, "", w)
        b = w; sub(/.*\//, "", b)
        if (w ~ /tools\// && index(tools, " " b " ")) { print src "\ttools/" b; next }
        if (index(tests, " " b " ")) { print src "\ttests/" b; next }
        if (index(tools, " " b " ")) { print src "\ttools/" b; next }
    }'
}

invocations() {   # invocations <file>  -> resolved, sorted, unique
    invoked_words "$1" | resolve_words | cut -f2 | sort -u
}

if [ "${1:-}" = "--invocations" ]; then
    shift
    [ "$#" -gt 0 ] || { echo "test-enrolment: --invocations needs at least one file" >&2; exit 2; }
    for f in "$@"; do
        [ -f "$f" ] || { echo "test-enrolment: --invocations: no such file $f" >&2; exit 2; }
        invocations "$f"
    done | sort -u
    exit 0
fi

# ---------------------------------------------------------------------------
# --selftest: every plant runs the REAL gate (this file, unmodified) against
# a copy of the tree it reads, and must fail for the NAMED reason.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
    ST=$(mktemp -d "${TMPDIR:-/tmp}/eigs_enrol_st.XXXXXX") || exit 2
    trap 'rm -rf "$ST"' EXIT
    st_rc=0; st_n=0
    fresh() {   # a clean copy of exactly what the gate reads
        rm -rf "$ST/tree"; mkdir -p "$ST/tree/.github" "$ST/tree/tests" "$ST/tree/tools"
        cp tests/*.sh tests/*.py "$ST/tree/tests/"
        [ -f "$EXEMPT_FILE" ] && cp "$EXEMPT_FILE" "$ST/tree/tests/"
        cp tools/*.sh tools/*.py "$ST/tree/tools/"
        cp -R .github/workflows "$ST/tree/.github/"
    }
    st_case() {   # st_case <name> <want-rc> <expected substring>
        local name="$1" want_rc="$2" want="$3" out rc
        st_n=$((st_n + 1))
        out=$(ENROL_ROOT="$ST/tree" bash "$SELF" 2>&1); rc=$?
        if [ "$rc" -ne "$want_rc" ]; then
            echo "  SELFTEST FAIL: $name -- exit $rc, wanted $want_rc" >&2
            printf '%s\n' "$out" | sed 's/^/      /' >&2; st_rc=1
        elif ! grep -qF -- "$want" <<< "$out"; then
            echo "  SELFTEST FAIL: $name -- right exit, wrong reason; wanted '$want'" >&2
            printf '%s\n' "$out" | sed 's/^/      /' >&2; st_rc=1
        else
            echo "  selftest ok: $name"
        fi
    }
    plant_sed() {   # plant_sed <file> <sed-program> -- refuses a no-op plant
        local f="$ST/tree/$1"
        cp "$f" "$f.orig"; sed "$2" "$f.orig" > "$f"
        if cmp -s "$f" "$f.orig"; then
            echo "  SELFTEST BROKEN: plant on $1 changed nothing -- the fault never existed" >&2
            st_rc=1
        fi
        rm -f "$f.orig"
    }

    fresh
    st_case "control: the unmodified tree passes" 0 "PASS: test-enrolment"

    fresh
    printf '#!/bin/bash\necho "PASS: planted"\n' > "$ST/tree/tests/test_zz_plant.sh"
    st_case "an uninvoked tests/test_zz_plant.sh is red and named" 1 "tests/test_zz_plant.sh is invoked by nothing"

    fresh
    printf 'print("PASS: planted")\n' > "$ST/tree/tests/test_zz_plant.py"
    st_case "an uninvoked tests/*.py is red and named" 1 "tests/test_zz_plant.py is invoked by nothing"

    # Remove the INVOCATION and keep the section's echo that still names the
    # file: a mention is not an enrolment.
    fresh
    plant_sed tests/run_all_tests.sh 's|bash "\$TESTS_DIR/test_args_import[.]sh"|true|'
    if grep -q 'test_args_import.sh' "$ST/tree/tests/run_all_tests.sh"; then
        st_case "runner invocation removed, echo still names it: red" 1 "tests/test_args_import.sh is invoked by nothing"
    else
        echo "  SELFTEST BROKEN: the runner no longer mentions test_args_import.sh outside the invocation -- this plant no longer tests mention-vs-invocation" >&2
        st_rc=1
    fi

    # A workflow-only enrolment (the transverse root).
    fresh
    plant_sed .github/workflows/ci.yml 's|bash tests/test_amalgamation[.]sh|echo tests/test_amalgamation.sh|'
    st_case "workflow invocation removed: red" 1 "tests/test_amalgamation.sh is invoked by nothing"

    # Transitive: test_dap.py is reached only through test_dap.sh.
    fresh
    plant_sed tests/run_all_tests.sh 's|bash "\$TESTS_DIR/test_dap[.]sh"|true|g'
    st_case "transitive: dropping test_dap.sh also orphans test_dap.py" 1 "tests/test_dap.py is invoked by nothing"

    # Launcher spellings the matcher must still see as invocations.
    fresh
    printf '#!/bin/bash\necho "PASS: planted"\n' > "$ST/tree/tests/test_zz_plant.sh"
    printf '\nif FOO="a b" timeout 30 bash "$TESTS_DIR/test_zz_plant.sh" >/dev/null; then :; fi\n' >> "$ST/tree/tests/run_all_tests.sh"
    st_case "VAR=value + timeout N launcher still counts as an invocation" 0 "PASS: test-enrolment"

    # Exemptions: stale (enrolled), missing file, no reason.
    fresh
    printf 'tests/test_args_import.sh | planted stale exemption\n' >> "$ST/tree/$EXEMPT_FILE"
    st_case "an exemption for an ENROLLED script is stale: red" 1 "exempts tests/test_args_import.sh, which IS invoked"
    fresh
    printf 'tests/test_no_such_file.sh | planted\n' >> "$ST/tree/$EXEMPT_FILE"
    st_case "an exemption for a missing file is stale: red" 1 "exempts tests/test_no_such_file.sh, which does not exist"
    fresh
    printf '#!/bin/bash\n' > "$ST/tree/tests/test_zz_plant.sh"
    printf 'tests/test_zz_plant.sh |   \n' >> "$ST/tree/$EXEMPT_FILE"
    st_case "an exemption without a reason: red" 1 "has no reason"
    fresh
    printf '#!/bin/bash\n' > "$ST/tree/tests/test_zz_plant.sh"
    printf 'tests/test_zz_plant.sh | planted, reasoned\n' >> "$ST/tree/$EXEMPT_FILE"
    st_case "a reasoned exemption for an unenrolled script passes" 0 "PASS: test-enrolment"

    # Instrument failure is not a verdict: no roots -> exit 2.
    fresh
    rm -rf "$ST/tree/.github/workflows" "$ST/tree/tests/run_all_tests.sh"
    st_case "no roots is an instrument failure (exit 2), not a pass" 2 "no roots"

    echo "  checks=$st_n"
    if [ "$st_rc" -eq 0 ]; then echo "SELFTEST: all $st_n cases behaved"; else echo "SELFTEST: FAILED"; fi
    exit "$st_rc"
fi

# ---------------------------------------------------------------------------
# The audit.
# ---------------------------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs_enrol.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT

: > "$WORK/roots"
[ -f tests/run_all_tests.sh ] && echo tests/run_all_tests.sh >> "$WORK/roots"
for y in .github/workflows/*.yml; do [ -f "$y" ] && echo "$y" >> "$WORK/roots"; done
n_roots=$(grep -c . "$WORK/roots")
if [ "$n_roots" -eq 0 ] || [ ! -f tests/run_all_tests.sh ]; then
    echo "test-enrolment: ABORTED (no instrument): no roots -- tests/run_all_tests.sh or .github/workflows/*.yml missing" >&2
    exit 2
fi

# The population, by glob -- NOT git ls-files: a contributor's new, untracked
# test is exactly the case this gate exists for.
for f in tests/*.sh tests/*.py; do [ -f "$f" ] && echo "$f"; done | sort > "$WORK/pop"
n_pop=$(grep -c . "$WORK/pop")
# §122: a second, different enumeration of the same population must agree.
n_pop_find=$(find tests -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) | grep -c .)
if [ "$n_pop" -eq 0 ]; then
    echo "test-enrolment: ABORTED (no instrument): the population tests/*.sh + tests/*.py is EMPTY" >&2; exit 2
fi
if [ "$n_pop" -ne "$n_pop_find" ]; then
    echo "test-enrolment: ABORTED (no instrument): glob found $n_pop scripts, find found $n_pop_find -- the enumeration is broken" >&2; exit 2
fi

# Every edge in one pass (src<TAB>target), then the closure from the roots.
# Python files are targets, never sources: the matcher reads shell.
EDGE_SRC=$( { cat "$WORK/roots"; for f in tests/*.sh tools/*.sh; do [ -f "$f" ] && echo "$f"; done; } | sort -u)
# shellcheck disable=SC2086
invoked_words $EDGE_SRC | resolve_words | sort -u > "$WORK/edges"
awk -F'\t' -v roots="$(tr '\n' ' ' < "$WORK/roots")" '
    { adj[$1] = adj[$1] " " $2 }
    END {
        n = split(roots, q, " "); head = 1
        for (i = 1; i <= n; i++) seen[q[i]] = 1
        while (head <= n) {
            u = q[head++]; m = split(adj[u], t, " ")
            for (j = 1; j <= m; j++) {
                v = t[j]; if (v == "") continue
                reached[v] = 1
                if (!(v in seen)) { seen[v] = 1; q[++n] = v }
            }
        }
        for (v in reached) print v
    }' "$WORK/edges" | sort > "$WORK/reached"
awk -F'\t' '$1 == "tests/run_all_tests.sh" { print $2 }' "$WORK/edges" > "$WORK/direct_runner"
awk -F'\t' '$1 ~ /^\.github\// { print $2 }' "$WORK/edges" > "$WORK/direct_wf"

# Exemptions.
RC=0
fail() { echo "  FAIL: $*"; RC=1; }
: > "$WORK/exempt"
n_exempt=0
if [ -f "$EXEMPT_FILE" ]; then
    lineno=0
    while IFS= read -r raw || [ -n "$raw" ]; do
        lineno=$((lineno + 1))
        case "$raw" in ''|'#'*) continue ;; esac
        path="${raw%%|*}"; reason="${raw#*|}"
        path="$(printf '%s' "$path" | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')"
        reason="$(printf '%s' "$reason" | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')"
        if [ "$raw" = "${raw%%|*}" ] || [ -z "$reason" ]; then
            fail "$EXEMPT_FILE:$lineno exempts '$path' but has no reason (format: path | reason)"; continue
        fi
        n_exempt=$((n_exempt + 1))
        if [ ! -f "$path" ]; then
            fail "$EXEMPT_FILE:$lineno exempts $path, which does not exist -- stale exemption, delete the row"
        elif grep -qxF "$path" "$WORK/reached"; then
            fail "$EXEMPT_FILE:$lineno exempts $path, which IS invoked by CI -- the exemption is not needed, delete the row"
        fi
        echo "$path" >> "$WORK/exempt"
    done < "$EXEMPT_FILE"
fi

n_enrolled=0; n_unenrolled=0; n_exempt_used=0
while IFS= read -r f; do
    if grep -qxF "$f" "$WORK/reached"; then
        n_enrolled=$((n_enrolled + 1))
    elif grep -qxF "$f" "$WORK/exempt"; then
        n_exempt_used=$((n_exempt_used + 1))
    else
        n_unenrolled=$((n_unenrolled + 1))
        fail "$f is invoked by nothing -- no suite section in tests/run_all_tests.sh, no .github/workflows/*.yml step, and no enrolled script runs it. Enrol it (add a section), or list it in $EXEMPT_FILE with a reason"
    fi
done < "$WORK/pop"

n_direct_runner=$(sort -u "$WORK/direct_runner" | grep -c '^tests/' || true)
n_direct_wf=$(sort -u "$WORK/direct_wf" | grep -c '^tests/' || true)
examined=$((n_enrolled + n_exempt_used + n_unenrolled))
if [ "$examined" -ne "$n_pop" ]; then
    echo "test-enrolment: ABORTED (no instrument): examined $examined of $n_pop scripts -- an entry fell through" >&2; exit 2
fi

if [ "$RC" -eq 0 ]; then
    echo "PASS: test-enrolment: examined=$n_pop (tests/*.sh + tests/*.py) enrolled=$n_enrolled exempt=$n_exempt_used; roots=$n_roots (runner invokes $n_direct_runner tests/ scripts directly, workflows $n_direct_wf)"
else
    echo "test-enrolment: FAIL: examined=$n_pop enrolled=$n_enrolled exempt=$n_exempt_used unenrolled=$n_unenrolled"
fi
exit "$RC"
