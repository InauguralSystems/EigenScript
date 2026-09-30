#!/usr/bin/env bash
# CI scope (the `scope` job in .github/workflows/ci.yml): does a PR change
# anything but docs? Prints `code=true` or `code=false`.
#
#   tools/ci_scope.sh BASE HEAD     classify the diff BASE..HEAD
#   tools/ci_scope.sh --selftest    build tiny histories and check each verdict
#
# Any path not ending in .md means the runtime could be affected. CHANGELOG.md
# and changes/ fragments are gated by tools/changelog_fragments.sh (precheck),
# so they are not docs-only either (#1268). Both sides of a rename count
# (#1311): `git mv src/foo.c notes.md` removes a C source from the build, and a
# diff that shows only the NEW name read it as docs-only.
set -euo pipefail

classify() {
    local files
    files=$(git diff --name-only --no-renames "$1" "$2")
    [ -n "$files" ] || { echo "ci_scope: empty diff $1..$2" >&2; echo "code=true"; return; }
    echo "changed files:" >&2; printf '%s\n' "$files" | sed 's/^/  /' >&2
    local f
    while IFS= read -r f; do
        case "$f" in CHANGELOG.md|changes/*) echo "code=true"; return ;; *.md) ;; *) echo "code=true"; return ;; esac
    done <<< "$files"
    echo "code=false"
}

selftest() {
    local fail=0 n=0 got
    d=$(mktemp -d "${TMPDIR:-/tmp}/ci_scope.XXXXXX"); trap 'rm -rf "$d"' EXIT   # global: the trap outlives the function
    git -C "$d" init -q
    git -C "$d" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
    mkdir -p "$d/src"; echo 'int x;' > "$d/src/foo.c"; echo doc > "$d/README.md"
    git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@t commit -q -m base
    # case <name> <want> <mutation>: apply the mutation on a branch off base
    case_() {
        local name="$1" want="$2"; shift 2
        git -C "$d" checkout -q -B "t$n" master 2>/dev/null || git -C "$d" checkout -q -B "t$n" main
        ( cd "$d" && eval "$*" )
        git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@t commit -q -m "$name"
        got=$(cd "$d" && classify HEAD~1 HEAD 2>/dev/null)
        n=$((n + 1))
        if [ "$got" = "code=$want" ]; then echo "  PASS: $name -> $got"
        else echo "  FAIL: $name -> $got, want code=$want"; fail=$((fail + 1)); fi
    }
    case_ "code edit"          true  'echo "int y;" >> src/foo.c'
    case_ "docs edit"          false 'echo more >> README.md'
    case_ "rename .c to .md"   true  'git mv src/foo.c notes.md'
    case_ "delete .c"          true  'git rm -q src/foo.c'
    case_ "rename .md to .md"  false 'git mv README.md GUIDE.md'
    case_ "CHANGELOG.md edit"  true  'echo entry > CHANGELOG.md'
    case_ "changes/ fragment"  true  'mkdir -p changes/fixed && echo "- x" > changes/fixed/1-x.md'
    [ "$n" -eq 7 ] || { echo "ci_scope selftest: ran $n cases, want 7"; exit 1; }
    echo "ci_scope selftest: $((n - fail))/$n passed"
    [ "$fail" -eq 0 ]
}

case "${1:-}" in
    --selftest) selftest ;;
    -*|"") echo "usage: tools/ci_scope.sh BASE HEAD | --selftest" >&2; exit 2 ;;
    *) [ $# -eq 2 ] || { echo "usage: tools/ci_scope.sh BASE HEAD" >&2; exit 2; }; classify "$1" "$2" ;;
esac
