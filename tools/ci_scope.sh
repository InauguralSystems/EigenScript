#!/usr/bin/env bash
# CI scope (the `scope` job in .github/workflows/ci.yml): does a PR change
# anything but docs? Prints `code=true` or `code=false`.
#
#   tools/ci_scope.sh BASE HEAD     classify the diff BASE..HEAD
#   tools/ci_scope.sh --selftest    build tiny histories and check each verdict
#
# It fails CLOSED: a path is docs only when it is plainly docs, and anything it
# cannot classify as plain docs is code. Plain docs means all of the following:
# - the path ends in .md and is printed unquoted. git's quoting is pinned
#   (core.quotePath=true), so a path with non-ASCII bytes, a quote, a backslash
#   or a control character keeps its quotes, never ends in .md, and is code;
# - the path is not CHANGELOG.md, not a changes/ fragment (both are gated by
#   tools/changelog_fragments.sh, #1268) and not under tests/, which holds the
#   suite's inputs (no test reads a .md there today, but a new fixture could);
# - on each side of the diff the entry is absent or a regular file (mode 100644
#   or 100755). A symlink can expose a runtime file under a .md name, and a
#   submodule or a directory is never docs.
# Both sides of a rename count (#1311): `git mv src/foo.c notes.md` removes a C
# source from the build, and a diff that shows only the NEW name read it as
# docs-only. An empty diff or a git failure is code too (the script stops).
set -euo pipefail

classify() {
    # TEMPORARY (#1777 demonstration c, reverted by the next commit): every
    # diff reads as docs-only, so this PR shows a docs-only PR's scope.
    echo "code=false"; return
    local files
    files=$(git -c core.quotePath=true diff --name-only --no-renames "$1" "$2")
    [ -n "$files" ] || { echo "ci_scope: empty diff $1..$2" >&2; echo "code=true"; return; }
    echo "changed files:" >&2; printf '%s\n' "$files" | sed 's/^/  /' >&2
    local f e old_entry new_entry
    while IFS= read -r f; do
        # name-only classification is insufficient for symlinks: docs/x.md may
        # expose src/x.c. Inspect both trees: only an absent entry or a regular
        # file can be docs, so a changed or deleted link, a submodule or a
        # directory cannot hide behind a documentation suffix.
        old_entry=$(git ls-tree "$1" -- "$f")
        new_entry=$(git ls-tree "$2" -- "$f")
        for e in "$old_entry" "$new_entry"; do
            case "$e" in ""|"100644 "*|"100755 "*) ;; *) echo "code=true"; return ;; esac
        done
        case "$f" in CHANGELOG.md|changes/*|tests/*) echo "code=true"; return ;; *.md) ;; *) echo "code=true"; return ;; esac
    done <<< "$files"
    echo "code=false"
}

selftest() {
    local fail=0 n=0 got
    d=$(mktemp -d "${TMPDIR:-/tmp}/ci_scope.XXXXXX"); trap 'rm -rf "$d"' EXIT   # global: the trap outlives the function
    git -C "$d" init -q; git -C "$d" symbolic-ref HEAD refs/heads/base   # pinned: init.defaultBranch may be anything
    git -C "$d" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
    mkdir -p "$d/src"; echo 'int x;' > "$d/src/foo.c"; echo doc > "$d/README.md"
    git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@t commit -q -m base
    # case <name> <want> <mutation>: apply the mutation on a branch off base
    case_() {
        local name="$1" want="$2"; shift 2
        git -C "$d" checkout -q -B "t$n" base
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
    case_ "docs symlink to code" true 'mkdir -p docs && ln -s ../src/foo.c docs/link.md'
    # Fail closed (#1777): what git quotes, a .md under tests/ and a non-file entry are code.
    case_ "non-ASCII docs path, quoted by git" true 'mkdir -p docs && echo x > "docs/$(printf "\303\251").md"'
    case_ "non-ASCII code path" true 'echo "int z;" > "src/$(printf "\303\251").c"'
    case_ "docs path with a space" false 'mkdir -p docs && echo x > "docs/a b.md"'
    case_ "code path with a space" true 'echo "int s;" > "src/a b.c"'
    case_ ".md under tests/" true 'mkdir -p tests && echo x > tests/fixture.md'
    case_ "submodule named .md" true 'git update-index --add --cacheinfo 160000,"$(git rev-parse HEAD)",docs/sub.md && mkdir -p docs/sub.md'
    [ "$n" -eq 14 ] || { echo "ci_scope selftest: ran $n cases, want 14"; exit 1; }
    echo "ci_scope selftest: $((n - fail))/$n passed"
    [ "$fail" -eq 0 ]
}

case "${1:-}" in
    --selftest) selftest ;;
    -*|"") echo "usage: tools/ci_scope.sh BASE HEAD | --selftest" >&2; exit 2 ;;
    *) [ $# -eq 2 ] || { echo "usage: tools/ci_scope.sh BASE HEAD" >&2; exit 2; }; classify "$1" "$2" ;;
esac
