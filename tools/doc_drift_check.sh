#!/bin/bash
# Mechanical doc-drift audit — cheap greps for the staleness classes
# that have actually occurred (found v0.24.0-vs-v0.26.0 CLAUDE.md drift
# the day it was written). Exit nonzero on drift. Runs in the suite
# ([98]) and is cron-able: the LLM-free half of "check for stale docs
# on its own"; prose-level drift needs the scheduled headless audit.
cd "$(dirname "$0")/.." || exit 1
drift=0

# 1. Every stdlib module has a STDLIB.md heading.
for m in lib/*.eigs; do
    stem=$(basename "$m")
    if ! grep -q "lib/$stem" docs/STDLIB.md; then
        echo "DRIFT: lib/$stem has no docs/STDLIB.md entry"
        drift=1
    fi
done

# 2. CLAUDE.md's "Latest release" line names the latest tag.
tag=$(git tag --sort=-v:refname | head -1)
if [ -n "$tag" ] && ! grep -q "Latest release: ${tag}" CLAUDE.md; then
    echo "DRIFT: CLAUDE.md 'Latest release' line is not ${tag}"
    drift=1
fi

# 3. A released VERSION always has its CHANGELOG section.
v=$(cat VERSION)
if ! grep -q "^## \[$v\]" CHANGELOG.md; then
    echo "DRIFT: CHANGELOG.md has no [$v] section for the current VERSION"
    drift=1
fi

# 4. README's "N-module standard library" headline equals its own table.
rows=$(grep -c '^| `lib/' README.md)
claim=$(grep -oE '[0-9]+-module standard library' README.md | grep -oE '^[0-9]+')
if [ -n "$claim" ] && [ "$claim" != "$rows" ]; then
    echo "DRIFT: README claims ${claim}-module stdlib but its table has ${rows} rows"
    drift=1
fi

exit $drift
