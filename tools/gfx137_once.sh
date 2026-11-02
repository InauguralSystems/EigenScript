#!/usr/bin/env bash
# #2320: section [137] (the ext_gfx.c ASan+UBSan+LSan corpus, #1007) runs ONCE
# per CI run instead of in every Linux lane.
#
# [137] never runs the lane's own binary. tests/test_asan_gfx.sh compiles its
# own (CC=${EIGS_ASAN_GFX_CC:-gcc}, SRC_V_asan-gfx, fixed -D flags), so every
# Linux container lane built the same gcc binary in the same dev image and
# judged the same corpus -- six copies of one verdict per queue run. linux /
# gcc owns it now; the other lanes DEFER, and a deferral is a counted skip that
# names the owner and must be on the reviewed allowlist.
#
#   tools/gfx137_once.sh defer LANE     the runner's [137] asks: may LANE defer?
#                                       rc 0 + the skip reason, or rc 1 + why not
#   tools/gfx137_once.sh scope BASE HEAD
#                                       PR scope for the owner: gfx137=true when
#                                       BASE..HEAD touches a [137] input
#   tools/gfx137_once.sh receipt LOG    the owner lane's own check: LOG must show
#                                       [137] RAN (or, when EIGS_GFX137_DEFER is
#                                       set, that it deferred under that id)
#
# The static half -- exactly one Linux lane runs [137] in the queue, no native
# lane defers, no stale or unlisted id -- is tests/test_gfx137_once_2320.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALLOW="${GFX137_ALLOWLIST:-$ROOT/tests/gfx137_defer_allowlist.txt}"

# The files whose change can change [137]'s verdict AND that are specific to
# it. The binary is built from every hosted source, but a change elsewhere in
# src/ is judged by the merge queue, where the owner runs [137] on every
# candidate unscoped; this list only decides whether a PR gets that answer
# early. The dev image (.devcontainer/Dockerfile: gcc, the ASan runtime, SDL2)
# and the compiler guard wrappers (tools/cc-guard-bin/) are here because they
# change the toolchain [137] builds with. lib/ui*.eigs is not here: no corpus
# program loads or imports a module.
INPUT_RE='^(src/ext_gfx[^/]*|\.devcontainer/Dockerfile|tools/cc-guard-bin/.*|tests/gfx_asan_corpus/.*|tests/test_asan_gfx\.sh|tests/lsan_classify\.sh|tests/test_gfx_timeout\.py|tools/werror_flags\.txt|tools/read_werror_flags\.sh|Makefile|tests/run_all_tests\.sh|tools/gfx137_once\.sh|tests/gfx137_defer_allowlist\.txt)$'

# allow_rows -> "id|owner|reason" per entry; rc 1 (with the reason on stderr)
# when the file is unreadable, empty, malformed, or has a duplicate id.
allow_rows() {
    [ -r "$ALLOW" ] || { echo "gfx137: allowlist $ALLOW is not readable" >&2; return 1; }
    awk -F'|' '
        /^[[:space:]]*(#|$)/ { next }
        {
            id = $1; owner = $2; reason = $0
            sub(/^[^|]*\|[^|]*\|/, "", reason)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", owner)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", reason)
            if (NF < 3 || id !~ /^[a-z0-9][a-z0-9-]*$/ || owner == "" || reason == "") {
                printf "gfx137: %s:%d: want `lane-id | owner | reason` with all three non-empty: %s\n", FILENAME, NR, $0 > "/dev/stderr"; bad = 1; next
            }
            if (id in seen) { printf "gfx137: %s:%d: duplicate lane id %s\n", FILENAME, NR, id > "/dev/stderr"; bad = 1; next }
            seen[id] = 1; n++
            print id "|" owner "|" reason
        }
        END {
            if (n == 0 && !bad) { printf "gfx137: %s has no entries\n", FILENAME > "/dev/stderr"; bad = 1 }
            exit bad
        }' "$ALLOW"
}

case "${1:-}" in
    defer)
        [ $# -eq 2 ] || { echo "usage: tools/gfx137_once.sh defer LANE" >&2; exit 2; }
        rows=$(allow_rows) || exit 1
        row=$(printf '%s\n' "$rows" | awk -F'|' -v id="$2" '$1 == id' )
        if [ -z "$row" ]; then
            echo "gfx137: lane '$2' is not on the reviewed allowlist $ALLOW -- [137] may not be skipped there"
            exit 1
        fi
        owner=$(printf '%s\n' "$row" | cut -d'|' -f2)
        echo "[137] deferred in lane $2 to $owner (#2320, tests/gfx137_defer_allowlist.txt)"
        ;;
    scope)
        [ $# -eq 3 ] || { echo "usage: tools/gfx137_once.sh scope BASE HEAD" >&2; exit 2; }
        # Both sides of a rename count, as in tools/ci_scope.sh (#1311). A git
        # failure stops the script (set -e) and fails the scope job; an empty
        # diff runs [137] (fail closed).
        files=$(git -c core.quotePath=true diff --name-only --no-renames "$2" "$3")
        if [ -z "$files" ]; then echo "gfx137: empty diff $2..$3 -- running [137]" >&2; echo "gfx137=true"; exit 0; fi
        hits=$(printf '%s\n' "$files" | grep -E "$INPUT_RE" || true)
        if [ -n "$hits" ]; then
            printf '%s\n' "$hits" | sed 's/^/gfx137: [137] input changed: /' >&2
            echo "gfx137=true"
        else
            echo "gfx137: no [137] input changed -- linux / gcc defers it to the merge queue" >&2
            echo "gfx137=false"
        fi
        ;;
    receipt)
        [ $# -eq 2 ] || { echo "usage: tools/gfx137_once.sh receipt LOG" >&2; exit 2; }
        [ -r "$2" ] || { echo "gfx137: receipt: suite log $2 is not readable"; exit 1; }
        ran=$(grep -c '^  GFX137: ran$' "$2" || true)
        deferred=$(grep -c '^  GFX137: deferred lane=' "$2" || true)
        if [ -z "${EIGS_GFX137_DEFER:-}" ]; then
            if [ "$ran" = 1 ] && [ "$deferred" = 0 ]; then
                echo "gfx137: receipt OK -- this lane owns [137] and it ran clean"
            else
                echo "gfx137: receipt FAIL -- this lane owns [137] but its log has ran=$ran deferred=$deferred (want 1 and 0): [137] skipped, deferred, failed or never reached"
                exit 1
            fi
        else
            want="  GFX137: deferred lane=$EIGS_GFX137_DEFER"
            if [ "$ran" = 0 ] && [ "$deferred" = 1 ] && grep -qxF "$want" "$2"; then
                echo "gfx137: receipt OK -- [137] deferred under '$EIGS_GFX137_DEFER'"
            else
                echo "gfx137: receipt FAIL -- want exactly '$want' and no run; log has ran=$ran deferred=$deferred"
                exit 1
            fi
        fi
        ;;
    *)
        echo "usage: tools/gfx137_once.sh defer LANE | scope BASE HEAD | receipt LOG" >&2
        exit 2 ;;
esac
