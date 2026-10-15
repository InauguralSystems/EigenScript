#!/usr/bin/env bash
# CI scope (the `scope` job in .github/workflows/ci.yml): what does a PR
# change? Prints two lines:
#   code=true|false      anything but docs: the runtime legs read it
#   observer=true|false  a path of the observer oracle's lane (#1778): the
#                        required `observer oracle (v0.46.0 floor)` job does
#                        its work on a pull request only when this is true
# Outside a pull request (merge_group, push) the scope job does not run this
# script and prints only code=true, so the observer output is empty and the
# floor always runs there.
#
#   tools/ci_scope.sh BASE HEAD     classify the diff BASE..HEAD
#   tools/ci_scope.sh --selftest    build tiny histories and check each verdict
#
# Any path not ending in .md means the runtime could be affected. A symlink at
# either side of the diff is code regardless of its name: its target can be a
# runtime file even when the link itself ends in .md. CHANGELOG.md
# and changes/ fragments are gated by tools/changelog_fragments.sh (precheck),
# so they are not docs-only either (#1268). Both sides of a rename count
# (#1311): `git mv src/foo.c notes.md` removes a C source from the build, and a
# diff that shows only the NEW name read it as docs-only.
#
# The observer lane's paths: the observer and the six predicates
# (src/eigenscript.c, its state and thresholds in src/eigenscript.h), the
# opcodes that run them (src/vm.c, src/vm.h), the compiler that picks those
# opcodes and the observer gate (src/compiler.c, src/chunk.c), the seeded
# thresholds (src/state.c), the JIT, lib/observer.eigs, and the lane's own
# inputs: the Makefile, the oracle, ci.yml and the dev image. A path matches
# as a shell case pattern, where `*` also crosses `/`; both sides of a rename
# count here too.
set -euo pipefail
# TEMPORARY (#1778 demonstration (b), reverted by the next commit): without the
# three lane paths this PR touches (Makefile, tools/observer_oracle/*, ci.yml),
# the PR is outside the lane, so the required check must be skipped (passing).
# ci_scope.sh --selftest fails in this run by construction.
OBSERVER_PATHS=(src/eigenscript.c src/eigenscript.h src/vm.c src/vm.h src/compiler.c src/chunk.c src/state.c
                'src/jit*' lib/observer.eigs .devcontainer/Dockerfile)

classify() {
    local files
    files=$(git diff --name-only --no-renames "$1" "$2")
    [ -n "$files" ] || { echo "ci_scope: empty diff $1..$2" >&2; echo "code=true"; echo "observer=true"; return; }
    echo "changed files:" >&2; printf '%s\n' "$files" | sed 's/^/  /' >&2
    local f p old_entry new_entry code=false observer=false
    while IFS= read -r f; do
        if [ "$code" = false ]; then
            # name-only classification is insufficient for symlinks: docs/x.md may
            # expose src/x.c. Inspect both trees so a changed or deleted link cannot
            # hide behind a documentation suffix.
            old_entry=$(git ls-tree "$1" -- "$f")
            new_entry=$(git ls-tree "$2" -- "$f")
            case "$old_entry $new_entry" in *120000*) code=true ;; esac
            case "$f" in CHANGELOG.md|changes/*) code=true ;; *.md) ;; *) code=true ;; esac
        fi
        for p in "${OBSERVER_PATHS[@]}"; do
            # shellcheck disable=SC2254  # a glob on purpose: quoted, src/jit* and tools/observer_oracle/* match nothing
            case "$f" in $p) observer=true ;; esac
        done
    done <<< "$files"
    echo "code=$code"
    echo "observer=$observer"
}

selftest() {
    local fail=0 n=0 got
    d=$(mktemp -d "${TMPDIR:-/tmp}/ci_scope.XXXXXX"); trap 'rm -rf "$d"' EXIT   # global: the trap outlives the function
    git -C "$d" init -q; git -C "$d" symbolic-ref HEAD refs/heads/base   # pinned: init.defaultBranch may be anything
    git -C "$d" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
    mkdir -p "$d/src" "$d/lib"; echo 'int x;' > "$d/src/foo.c"; echo doc > "$d/README.md"
    echo 'int v;' > "$d/src/vm.c"; echo 'all:' > "$d/Makefile"; echo '# obs' > "$d/lib/observer_slots.eigs"
    git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@t commit -q -m base
    # case <name> <want code> <want observer> <mutation>: apply the mutation on a branch off base
    case_() {
        local name="$1" want="code=$2"$'\n'"observer=$3"; shift 3
        git -C "$d" checkout -q -B "t$n" base
        ( cd "$d" && eval "$*" )
        git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@t commit -q -m "$name"
        got=$(cd "$d" && classify HEAD~1 HEAD 2>/dev/null)
        n=$((n + 1))
        if [ "$got" = "$want" ]; then echo "  PASS: $name -> $(echo $got)"
        else echo "  FAIL: $name -> $(echo $got), want $(echo $want)"; fail=$((fail + 1)); fi
    }
    case_ "code edit"          true  false 'echo "int y;" >> src/foo.c'
    case_ "docs edit"          false false 'echo more >> README.md'
    case_ "rename .c to .md"   true  false 'git mv src/foo.c notes.md'
    case_ "delete .c"          true  false 'git rm -q src/foo.c'
    case_ "rename .md to .md"  false false 'git mv README.md GUIDE.md'
    case_ "CHANGELOG.md edit"  true  false 'echo entry > CHANGELOG.md'
    case_ "changes/ fragment"  true  false 'mkdir -p changes/fixed && echo "- x" > changes/fixed/1-x.md'
    case_ "docs symlink to code" true false 'mkdir -p docs && ln -s ../src/foo.c docs/link.md'
    case_ "observer source edit" true true 'echo "int w;" >> src/vm.c'
    case_ "src/jit* glob"      true  true  'echo "int j;" > src/jit_new.c'
    case_ "oracle file, nested" true true  'mkdir -p tools/observer_oracle/sub && echo "{}" > tools/observer_oracle/sub/x.json'
    case_ "rename out of the lane" true true 'git mv src/vm.c src/vm_old.c'
    case_ "Makefile edit"      true  true  'echo "x:" >> Makefile'
    case_ "near miss: observer_slots.eigs, vm.c.orig" true false 'echo "#" >> lib/observer_slots.eigs && echo x > src/vm.c.orig'
    [ "$n" -eq 14 ] || { echo "ci_scope selftest: ran $n cases, want 14"; exit 1; }
    echo "ci_scope selftest: $((n - fail))/$n passed"
    [ "$fail" -eq 0 ]
}

case "${1:-}" in
    --selftest) selftest ;;
    -*|"") echo "usage: tools/ci_scope.sh BASE HEAD | --selftest" >&2; exit 2 ;;
    *) [ $# -eq 2 ] || { echo "usage: tools/ci_scope.sh BASE HEAD" >&2; exit 2; }; classify "$1" "$2" ;;
esac
