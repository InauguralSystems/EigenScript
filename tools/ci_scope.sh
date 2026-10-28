#!/usr/bin/env bash
# CI scope (the `scope` job in .github/workflows/ci.yml): does a PR change
# anything but docs, does it affect the Lean spec, and must the release recipe
# be dry-run? Prints GitHub-output-compatible verdicts.
#
#   tools/ci_scope.sh BASE HEAD     classify the diff BASE..HEAD
#   tools/ci_scope.sh --all         conservatively enable every scope
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
    local files code=false spec=false release=false
    files=$(git -c core.quotePath=true diff --name-only --no-renames "$1" "$2")
    [ -n "$files" ] || { echo "ci_scope: empty diff $1..$2" >&2; printf 'code=true\nspec=true\nrelease=true\n'; return; }
    echo "changed files:" >&2; printf '%s\n' "$files" | sed 's/^/  /' >&2
    local f e old_entry new_entry
    while IFS= read -r f; do
        case "$f" in
            spec/*|tools/spec_lean_no_sorry.py|tools/spec_lean_axioms.py|tools/spec_lean_no_delegation.py|tools/spec_lean_classify.py|tools/spec_lean_corpus.py|tools/spec_lean_parity.py|tests/test_doc_examples.py|.github/workflows/ci.yml) spec=true ;;
        esac
        case "$f" in
            .github/workflows/release.yml|.github/workflows/ci.yml|.github/actions/release-build/*|.devcontainer/Dockerfile|tools/install_release_test_dependencies.sh|tests/run_all_tests.sh) release=true ;;
        esac
        # name-only classification is insufficient for symlinks: docs/x.md may
        # expose src/x.c. Inspect both trees: only an absent entry or a regular
        # file can be docs, so a changed or deleted link, a submodule or a
        # directory cannot hide behind a documentation suffix.
        old_entry=$(git ls-tree "$1" -- "$f")
        new_entry=$(git ls-tree "$2" -- "$f")
        for e in "$old_entry" "$new_entry"; do
            case "$e" in ""|"100644 "*|"100755 "*) ;; *) code=true ;; esac
        done
        case "$f" in CHANGELOG.md|changes/*|tests/*) code=true ;; *.md) ;; *) code=true ;; esac
    done <<< "$files"
    printf 'code=%s\nspec=%s\nrelease=%s\n' "$code" "$spec" "$release"
}

selftest() {
    local fail=0 n=0 got
    d=$(mktemp -d "${TMPDIR:-/tmp}/ci_scope.XXXXXX"); trap 'rm -rf "$d"' EXIT   # global: the trap outlives the function
    git -C "$d" init -q; git -C "$d" symbolic-ref HEAD refs/heads/base   # pinned: init.defaultBranch may be anything
    git -C "$d" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
    mkdir -p "$d/src"; echo 'int x;' > "$d/src/foo.c"; echo doc > "$d/README.md"
    git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@t commit -q -m base
    # case <name> <want-code> <want-spec> <want-release> <mutation>
    case_() {
        local name="$1" want_code="$2" want_spec="$3" want_release="$4"; shift 4
        git -C "$d" checkout -q -B "t$n" base
        ( cd "$d" && eval "$*" )
        git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@t commit -q -m "$name"
        got=$(cd "$d" && classify HEAD~1 HEAD 2>/dev/null)
        n=$((n + 1))
        if [ "$got" = "$(printf 'code=%s\nspec=%s\nrelease=%s' "$want_code" "$want_spec" "$want_release")" ]; then
            echo "  PASS: $name -> code=$want_code, spec=$want_spec, release=$want_release"
        else
            echo "  FAIL: $name -> $got, want code=$want_code spec=$want_spec release=$want_release"; fail=$((fail + 1))
        fi
    }
    case_ "code edit"          true false false 'echo "int y;" >> src/foo.c'
    case_ "docs edit"          false false false 'echo more >> README.md'
    case_ "rename .c to .md"   true false false 'git mv src/foo.c notes.md'
    case_ "delete .c"          true false false 'git rm -q src/foo.c'
    case_ "rename .md to .md"  false false false 'git mv README.md GUIDE.md'
    case_ "CHANGELOG.md edit"  true false false 'echo entry > CHANGELOG.md'
    case_ "changes/ fragment"  true false false 'mkdir -p changes/fixed && echo "- x" > changes/fixed/1-x.md'
    case_ "docs symlink to code" true false false 'mkdir -p docs && ln -s ../src/foo.c docs/link.md'
    # Fail closed (#1777): what git quotes, a .md under tests/ and a non-file entry are code.
    case_ "non-ASCII docs path, quoted by git" true false false 'mkdir -p docs && echo x > "docs/$(printf "\303\251").md"'
    case_ "non-ASCII code path" true false false 'echo "int z;" > "src/$(printf "\303\251").c"'
    case_ "docs path with a space" false false false 'mkdir -p docs && echo x > "docs/a b.md"'
    case_ "code path with a space" true false false 'echo "int s;" > "src/a b.c"'
    case_ ".md under tests/" true false false 'mkdir -p tests && echo x > tests/fixture.md'
    case_ "submodule named .md" true false false 'git update-index --add --cacheinfo 160000,"$(git rev-parse HEAD)",docs/sub.md && mkdir -p docs/sub.md'
    # The spec verdict is independent of the broad code verdict. The large
    # diff protects the single-pass classifier against the old grep/SIGPIPE bug.
    case_ "spec verdict: spec-only" false true false 'mkdir -p spec && echo x > spec/note.md'
    case_ "spec verdict: code-only" true false false 'echo "int spec_no;" >> src/foo.c'
    case_ "spec verdict: both" true true false 'mkdir -p tools && echo x > tools/spec_lean_axioms.py'
    case_ "spec verdict: neither" false false false 'echo neither >> README.md'
    case_ "spec verdict: corpus extractor" true true false 'mkdir -p tests && echo "# x" >> tests/test_doc_examples.py'
    case_ "spec verdict: large diff" true true true 'mkdir -p docs .github/workflows; i=0; while [ "$i" -lt 512 ]; do p=$(printf "%0200d" "$i"); echo x > "docs/$p.md"; i=$((i + 1)); done; echo "name: ci" > .github/workflows/ci.yml'
    case_ "release workflow" true false true 'mkdir -p .github/workflows && echo "name: release" > .github/workflows/release.yml'
    case_ "shared release dependencies" true false true 'mkdir -p tools && echo x > tools/install_release_test_dependencies.sh'
    # The merge-group scope job feeds its base_sha..head_sha through this same
    # classifier: release inputs select its workers, ordinary source does not.
    case_ "merge-group release diff" true false true 'mkdir -p .github/actions/release-build && echo x > .github/actions/release-build/action.yml'
    case_ "merge-group src-only diff" true false false 'echo "int queue;" >> src/foo.c'
    [ "$n" -eq 24 ] || { echo "ci_scope selftest: ran $n cases, want 24"; exit 1; }
    echo "ci_scope selftest: $((n - fail))/$n passed"
    [ "$fail" -eq 0 ]
}

case "${1:-}" in
    --all) [ $# -eq 1 ] || { echo "usage: tools/ci_scope.sh BASE HEAD | --all | --selftest" >&2; exit 2; }; printf 'code=true\nspec=true\nrelease=true\n' ;;
    --selftest) selftest ;;
    -*|"") echo "usage: tools/ci_scope.sh BASE HEAD | --all | --selftest" >&2; exit 2 ;;
    *) [ $# -eq 2 ] || { echo "usage: tools/ci_scope.sh BASE HEAD | --all | --selftest" >&2; exit 2; }; classify "$1" "$2" ;;
esac
