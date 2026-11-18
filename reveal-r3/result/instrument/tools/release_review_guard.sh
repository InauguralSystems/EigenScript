#!/bin/sh
# Require a legibility review of the released candidate and permit only the
# documented release bookkeeping between that candidate and the release commit.
set -eu

: "${TAG:?TAG is required}"

rec="docs/release-reviews/$TAG.md"
[ -f "$rec" ] || {
    echo "::error::$rec is missing: every release commits its documentation and configuration review first (docs/release-reviews/README.md)." >&2
    exit 1
}

# Ask the remote for this version's predecessor.  Excluding $TAG matters when
# re-releasing an older tag: a newer release must not become its predecessor.
previous=$({ git ls-remote --tags --refs origin 'v*' | sed 's|.*refs/tags/||' |
    grep -vxF "$TAG"; echo "$TAG"; } |
    sort -V | awk -v t="$TAG" '$0 == t { print prev; exit } { prev = $0 }')
[ -n "$previous" ] || { echo "::error::no previous release tag found on origin" >&2; exit 1; }

range=$(sed -n 's/^Range: //p' "$rec" | head -1)
case "$range" in
    "$previous"..????????????????????????????????????????) ;;
    *) echo "::error::$rec Range must be $previous..<40-hex SHA>" >&2; exit 1 ;;
esac
reviewed=${range#"$previous"..}
case "$reviewed" in
    *[!0-9a-f]*) echo "::error::$rec Range candidate is not a 40-hex SHA" >&2; exit 1 ;;
esac

release=$(git rev-parse --verify 'HEAD^{commit}')
if ! git merge-base --is-ancestor "$reviewed" "$release"; then
    echo "::error::$rec Range candidate $reviewed is not an ancestor of release commit $release" >&2
    exit 1
fi

# The release procedure commits the review record after reviewing the
# candidate.  Its only other documented cut outputs are VERSION and
# CHANGELOG.md; code (and every other path) must be part of the reviewed range.
bad_paths=$(git diff --name-only "$reviewed..$release" -- . \
    ':(exclude)docs/release-reviews/**' \
    ':(exclude)VERSION' \
    ':(exclude)CHANGELOG.md')
if [ -n "$bad_paths" ]; then
    echo "::error::unreviewed changes after Range candidate $reviewed:" >&2
    printf '%s\n' "$bad_paths" >&2
    exit 1
fi

if grep -Eq 'CANDIDATE_SHA|CRITIC_PENDING|REVIEW_PR' "$rec"; then
    echo "::error::$rec contains a release-review placeholder" >&2
    exit 1
fi
grep -q '^Verdict: ' "$rec" || { echo "::error::$rec has no 'Verdict:' line" >&2; exit 1; }
echo "release review: $rec ($(grep '^Verdict: ' "$rec" | head -1))"
