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
# The same scan enrols tools/ (mechanical-gates section 151, #1758 R1.3: Phase
# 2's two gate tools had run only on builders' machines). Every top-level
# tools/*.sh and tools/*.py is an entry point, and so is each tools/<dir>/
# package holding a script, by the directory listing, never a hand-kept list.
# Each must be reached from a .github/workflows/*.yml step through invocations
# (the suite, a top-level tests/, tools/ or bench/ shell script, a script beside it
# called as "$(dirname "$0")/x"), or be listed in the same exemptions file as
# local-only with its reason. Not seen: a tool run only through make, a Python
# subprocess or an import; a package counts as reached when CI runs any of its
# scripts. Static local uses: ./... steps also reach composite action manifests
# (action.yml or action.yaml), including nested local actions. Action manifests
# are graph sources, never roots: an unused action cannot enrol a tool.
# bench/*.sh also provide graph edges when reached; they are not new
# enrollment candidates (the candidate population remains tests/ and tools/).
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
    mkdir -p "$ST/tests/sections" "$ST/tools" "$ST/.github"
    cp tests/*.sh tests/*.py "$EXEMPT" "$ST/tests/" && cp tests/sections/*.sh "$ST/tests/sections/" \
        && cp tools/*.sh tools/*.py tools/selftests.txt "$ST/tools/" && cp -R .github bench "$ST/" \
        && for d in tools/*/; do cp -R "${d%/}" "$ST/tools/"; done
    n=0; bad=0
    case_() {   # case_ <name> <want-rc> <want-substring>
        local out rc; n=$((n + 1))
        out=$(ENROL_ROOT="$ST" bash "$SELF" 2>&1); rc=$?
        if [ "$rc" -eq "$2" ] && grep -qF -- "$3" <<< "$out"; then echo "  selftest ok: $1"
        else echo "  SELFTEST FAIL: $1 (rc=$rc, want $2 + '$3')"; printf '%s\n' "$out" | sed 's/^/      /'; bad=1; fi
    }
    mkdir -p "$ST/.github/actions/zz_enrol_leaf" "$ST/.github/actions/zz_enrol_parent"
    printf 'raise SystemExit(0)\n' > "$ST/tools/zz_plant_gate.py"
    # Keep fixture commands in printf arguments: literal run: lines in this
    # shell source would themselves be scanned as invocations.
    printf '%s\n' 'name: planted leaf' 'runs:' '  using: composite' '  steps:' \
        '    - shell: bash' '      run: python3 "$GITHUB_WORKSPACE/tools/zz_plant_gate.py"' \
        > "$ST/.github/actions/zz_enrol_leaf/action.yaml"
    printf '%s\n' 'name: planted parent' 'runs:' '  using: composite' '  steps:' \
        '  - uses: ./.github/actions/zz_enrol_leaf' \
        > "$ST/.github/actions/zz_enrol_parent/action.yml"
    printf '%s\n' 'name: planted workflow' 'on: push' 'jobs:' '  plant:' \
        '    runs-on: ubuntu-latest' '    steps:' \
        '      - uses: "./.github/actions/zz_enrol_parent"' \
        > "$ST/.github/workflows/zz_enrol.yaml"
    case_ "control: workflow and nested local actions reach their helpers" 0 "PASS: test-enrolment"
    # A bench script is an intermediate edge, never a root by itself.
    printf 'raise SystemExit(0)\n' > "$ST/tools/zz_bench_gate.py"
    printf '%s\n' '#!/bin/bash' 'python3 "$(dirname "$0")/../tools/zz_bench_gate.py"' \
        > "$ST/bench/zz_enrol.sh"
    printf '%s\n' 'name: planted bench workflow' 'on: push' 'jobs:' '  bench:' \
        '    runs-on: ubuntu-latest' '    steps:' \
        '      - run: bash bench/zz_enrol.sh' \
        > "$ST/.github/workflows/zz_enrol_bench.yaml"
    case_ "workflow reaches a helper through its bench script" 0 "PASS: test-enrolment"
    rm "$ST/.github/workflows/zz_enrol_bench.yaml"
    case_ "an orphan bench script cannot enrol its helper" 1 "tools/zz_bench_gate.py is invoked by no workflow"
    rm "$ST/bench/zz_enrol.sh" "$ST/tools/zz_bench_gate.py"
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
    sed -i.bak '$d' "$ST/$EXEMPT" && rm -f "$ST/$EXEMPT.bak"
    printf '#!/bin/bash\nexit 1\n' > "$ST/tools/zz_plant_gate.sh"
    mkdir -p "$ST/.github/actions/zz_enrol_orphan"
    printf '%s\n' 'name: planted orphan' 'runs:' '  using: composite' '  steps:' \
        '    - shell: bash' '      run: bash tools/zz_plant_gate.sh' \
        > "$ST/.github/actions/zz_enrol_orphan/action.yml"
    printf '%s\n' '      - run: true' '        env:' \
        '          uses: ./.github/actions/zz_enrol_orphan' \
        '      - run: |' '          cat <<TEXT' '          steps:' \
        '            - uses: ./.github/actions/zz_enrol_orphan' '          TEXT' \
        >> "$ST/.github/workflows/zz_enrol.yaml"
    # A scalar before any real steps makes scalar suppression independent of
    # the active-steps filter: dropping either guard must expose this orphan.
    printf '%s\n' 'name: |' '  steps:' \
        '    - uses: ./.github/actions/zz_enrol_orphan' 'on: push' 'jobs:' \
        '  noop:' '    runs-on: ubuntu-latest' '    steps:' '      - run: true' \
        > "$ST/.github/workflows/zz_enrol_scalar.yml"
    case_ "env and scalar text do not invoke an orphan action" 1 "tools/zz_plant_gate.sh is invoked by no workflow"
    rm "$ST/tools/zz_plant_gate.sh"
    sed -i.bak 's#uses: "./.github/actions/zz_enrol_parent"#run: true#' "$ST/.github/workflows/zz_enrol.yaml"
    rm -f "$ST/.github/workflows/zz_enrol.yaml.bak"
    case_ "removing workflow uses leaves tools/zz_plant_gate.py unenrolled" 1 "tools/zz_plant_gate.py is invoked by no workflow"
    rm "$ST/tools/zz_plant_gate.py"; mkdir "$ST/tools/zz_pkg"; printf 'raise SystemExit(1)\n' > "$ST/tools/zz_pkg/gate.py"
    case_ "an uninvoked package tools/zz_pkg/ is red and named" 1 "tools/zz_pkg/ is invoked by no workflow"
    echo "  checks=$n"
    exit "$bad"
fi

[ -f tests/run_all_tests.sh ] || { echo "test-enrolment: ABORTED: no tests/run_all_tests.sh"; exit 2; }
KNOWN=" $(cd tests && ls | tr '\n' ' ') "
EDGES=$(mktemp "${TMPDIR:-/tmp}/eigs_enrol.XXXXXX") || exit 2
trap 'rm -f "$EDGES"' EXIT
# Every edge "src<TAB>target" out of the roots and all tests/tools/bench shell
# scripts. Local uses steps add action manifests to awk input once; the
# closure below keeps only sources reached from workflows or the suite.
set -- tests/run_all_tests.sh tests/sections/*.sh tests/*.sh tools/*.sh bench/*.sh
for f in .github/workflows/*.yml .github/workflows/*.yaml; do
    [ ! -f "$f" ] || set -- "$@" "$f"
done
awk -v known="$KNOWN" '
function local_action(dir,   ext, path, probe, rc) {
    sub(/^\.\//, "", dir); sub(/\/+$/, "", dir)
    if (dir == "") dir = "."
    for (ext = 1; ext <= 2; ext++) {
        path = dir (ext == 1 ? "/action.yml" : "/action.yaml")
        rc = (getline probe < path); close(path)
        if (rc < 0) continue
        print FILENAME "\t" path
        if (!(path in actions)) { actions[path] = 1; ARGV[ARGC++] = path }
        return
    }
}
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
FNR == 1 { scalar_indent = steps_indent = step_indent = -1 }
{
    line = $0
    sub(/(^|[[:space:]])#.*$/, "", line)                  # a comment starts a word
    yaml = (FILENAME ~ /^\.github\/workflows\/[^\/]+\.ya?ml$|(^|\/)action\.ya?ml$/)
    in_scalar = step_use = 0
    if (yaml) {
        text = line; sub(/^[[:space:]]*/, "", text)
        indent = length(line) - length(text)
        if (text != "" && scalar_indent >= 0 && indent <= scalar_indent) scalar_indent = -1
        in_scalar = (scalar_indent >= 0)
        # Scalar contents are shell input, never YAML uses edges. A sequence
        # dash precedes the key, so measure the key column after that dash.
        if (!in_scalar && line ~ /:[[:space:]]*[|>]([+-][1-9]?|[1-9][+-]?)?[[:space:]]*$/) {
            keytext = text; sub(/^-[[:space:]]+/, "", keytext)
            scalar_indent = length(line) - length(keytext)
        }
        if (!in_scalar && text != "") {
            dash = (text ~ /^-([[:space:]]|$)/)
            # A steps sequence may start at its header column. Other keys at
            # that column end it; nested env/with keys are not step properties.
            if (steps_indent >= 0 && ((step_indent >= 0 && indent < step_indent) ||
                (indent <= steps_indent && !(dash && indent == steps_indent))))
                steps_indent = step_indent = -1
            if (steps_indent < 0 && text ~ /^steps:[[:space:]]*$/) {
                steps_indent = indent; step_indent = -1
            } else if (steps_indent >= 0) {
                if (step_indent < 0 && dash) step_indent = indent
                step_use = (step_indent >= 0 &&
                    ((indent == step_indent && text ~ /^-[[:space:]]+uses:[[:space:]]*/) ||
                     (indent == step_indent + 2 && text ~ /^uses:[[:space:]]*/)))
            }
        }
    }
    if (step_use) {
        dir = line; sub(/^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*/, "", dir)
        gsub(/["\047]/, "", dir); sub(/[[:space:]]+$/, "", dir)
        # Static paths stay inside the checkout; expressions are not edges.
        if (dir ~ /^\.\/[A-Za-z0-9_.\/-]*$/ && dir !~ /(^|\/)\.\.(\/|$)/) local_action(dir)
        next
    }
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
            while (s ~ /^-[A-Za-z]+[[:space:]]/)   # python3 -W error x.py: -W and -X take a word
                if (w ~ /^python/ && s ~ /^-[WX][[:space:]]/) sub(/^-[WX][[:space:]]+[^[:space:]]+[[:space:]]*/, "", s)
                else sub(/^-[A-Za-z]+[[:space:]]+/, "", s)
            w = s; sub(/[[:space:]].*/, "", w); gsub(/["\047]/, "", w)
        } else if (closed && s !~ /[[:space:]]/) continue   # `x.sh)` is a case pattern
        b = w; sub(/.*\//, "", b); d = w; sub(/\/?[^\/]*$/, "", d)
        # Only a path that RESOLVES under tests/ counts: tests/x, ../tests/x, $TESTS_DIR/x,
        # the dir of a tests/ script, or a bare name after `cd tests` — never $WORK/x (#1264 r2).
        intests = (d ~ /(^|\/)tests$|TESTS_DIR\}?$/) || (d == "$DIR" && FILENAME ~ /^tests\//) || (d == "" && FILENAME !~ /^tools\//)
        if (w !~ /tools\// && w ~ /\.(sh|py)$/ && intests && index(known, " " b " ")) print FILENAME "\ttests/" b
        else if (w ~ /tools\/([^\/]+\/)?[^\/]+\.(sh|py)$/) { t = w; sub(/^.*tools\//, "tools/", t); print FILENAME "\t" t }
        else if (w ~ /bench\/[^\/]+\.sh$/) { t = w; sub(/^.*bench\//, "bench/", t); print FILENAME "\t" t }
        else if (d == "$DIR" && FILENAME ~ /^tools\// && w ~ /\.(sh|py)$/) { t = FILENAME; sub(/[^\/]*$/, b, t); print FILENAME "\t" t }
    }
}' "$@" | sort -u > "$EDGES"
# Commands in the self-test table are reachable through its driver.
awk -F '[|]' '$0 !~ /^#/ {
    n = split($2, a, /[[:space:]]+/)
    for (i = 1; i <= n; i++) if (a[i] ~ /^tests\/.*\.(sh|py)$/) print "tools/selftests.sh\t" a[i]
}' tools/selftests.txt >> "$EDGES"
REACHED=$(awk -F'\t' '{ adj[$1] = adj[$1] " " $2 }
    END { q[1] = "tests/run_all_tests.sh"; n = 1
          for (f in adj) if (f ~ /^tests\/sections\/[^\/]+\.sh$/) q[++n] = f
          for (f in adj) if (f ~ /^\.github\/workflows\/[^\/]+\.ya?ml$/) q[++n] = f
          for (h = 1; h <= n; h++) { m = split(adj[q[h]], t, " ")
              for (j = 1; j <= m; j++) if (!(t[j] in seen)) { seen[t[j]] = 1; q[++n] = t[j]; print t[j] } } }' \
    "$EDGES") || { echo "test-enrolment: ABORTED: reachability scan failed"; exit 2; }

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
    else echo "  FAIL: $f is invoked by nothing -- add a suite section in tests/sections/ (or a workflow step), or list it in $EXEMPT with a reason"; rc=1; fi
done
[ "$total" -gt 0 ] || { echo "test-enrolment: ABORTED: tests/*.sh + tests/*.py is empty"; exit 2; }
tt=0; tok=0; tex=0
for f in tools/*.sh tools/*.py tools/*/; do
    case "$f" in
        */) pkg=0; for g in "$f"*.sh "$f"*.py; do [ -f "$g" ] && pkg=1; done; [ "$pkg" = 1 ] || continue
            grep -q "^$f" <<< "$REACHED" && hit=1 || hit=0 ;;
        *) [ -f "$f" ] || continue; grep -qxF "$f" <<< "$REACHED" && hit=1 || hit=0 ;;
    esac
    tt=$((tt + 1))
    if [ "$hit" = 1 ]; then tok=$((tok + 1))
    elif grep -q "^[[:space:]]*$f[[:space:]]*|" <<< "$EXEMPTED"; then tex=$((tex + 1))
    else echo "  FAIL: $f is invoked by no workflow -- run it from a .github/workflows/ step (or a script one runs), or list it in $EXEMPT as local-only with a reason"; rc=1; fi
done
[ "$tt" -gt 0 ] || { echo "tool-enrolment: ABORTED: tools/*.sh + tools/*.py is empty"; exit 2; }
[ "$rc" -eq 0 ] && echo "PASS: test-enrolment: examined=$total enrolled=$ok exempt=$ex; tools examined=$tt enrolled=$tok exempt=$tex"
exit "$rc"
