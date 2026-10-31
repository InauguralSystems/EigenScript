#!/bin/sh
# Refuse to publish a checkout that did not pass through main (#2217).
set -eu

: "${RELEASE_EVENT_NAME:?RELEASE_EVENT_NAME is required}"
: "${RELEASE_REF:?RELEASE_REF is required}"
: "${RELEASE_SHA:?RELEASE_SHA is required}"

if [ "$RELEASE_EVENT_NAME" = workflow_dispatch ] && [ "$RELEASE_REF" != refs/heads/main ]; then
    echo "::error::release dispatches must run from refs/heads/main (got $RELEASE_REF)" >&2
    exit 1
fi

# An existing tag can be older than the depth-one checkout used by Actions.
# Remove the shallow boundary before asking whether it belongs to main.
shallow=$(git rev-parse --git-path shallow)
if [ -f "$shallow" ] && ! git fetch --quiet --unshallow origin; then
    echo "::error::could not unshallow the release checkout" >&2
    exit 1
fi

# Use an explicit destination so the ancestry check never trusts a stale local
# remote-tracking ref.  ^{commit} also peels an annotated tag push to its commit.
if ! git fetch --quiet --no-tags origin \
    '+refs/heads/main:refs/remotes/origin/main'; then
    echo "::error::could not fetch origin/main for the release ancestry check" >&2
    exit 1
fi
if ! candidate=$(git rev-parse --verify "${RELEASE_SHA}^{commit}" 2>/dev/null); then
    echo "::error::release candidate $RELEASE_SHA is not a commit" >&2
    exit 1
fi

# An idempotent dispatch releases an already-existing tag rather than HEAD.
# Fetch and validate that tag's commit so the existing-tag path cannot bypass
# the ancestry check by dispatching from an otherwise valid main checkout.
if [ "$RELEASE_EVENT_NAME" = workflow_dispatch ] && [ -n "${RELEASE_TAG:-}" ] &&
    git ls-remote --exit-code --tags --refs origin "refs/tags/$RELEASE_TAG" >/dev/null 2>&1; then
    if ! git fetch --quiet --no-tags origin \
        "+refs/tags/$RELEASE_TAG:refs/tags/$RELEASE_TAG" ||
        ! candidate=$(git rev-parse --verify "refs/tags/${RELEASE_TAG}^{commit}" 2>/dev/null); then
        echo "::error::could not resolve existing release tag $RELEASE_TAG" >&2
        exit 1
    fi
fi
if ! git merge-base --is-ancestor "$candidate" refs/remotes/origin/main; then
    echo "::error::release candidate $candidate is not an ancestor of origin/main" >&2
    exit 1
fi

echo "release ancestry: $candidate is on origin/main"
