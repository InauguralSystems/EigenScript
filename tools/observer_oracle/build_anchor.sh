#!/bin/bash
# Build the observer oracle's floor anchor (#1758): EigenScript v0.46.0 (commit
# 4a3a5c19), the Makefile's release target (`make build`, one job), at a FIXED
# path. The tree is the tag's own files (git archive), so nothing in this
# checkout but the tag reaches the build. score.py --write-floor accepts only
# the binary this recipe stamps, and --floor re-measures it.
# usage: bash tools/observer_oracle/build_anchor.sh   (prints the binary's sha256)
set -euo pipefail
TAG=v0.46.0
COMMIT=4a3a5c1941568e9bc562c7c8221cff22dc8ba697
DIR=/tmp/eigs-oracle-anchor/v0.46.0            # fixed: floor.json names this path
here=$(cd "$(dirname "$0")" && pwd)
top=$(git -C "$here" rev-parse --show-toplevel)  # git archive from a subdirectory archives only it
if [ "$(git -C "$top" rev-parse "$TAG^{commit}")" != "$COMMIT" ]; then
    echo "build_anchor: tag $TAG is not commit $COMMIT" >&2
    exit 2
fi
rm -rf "$DIR"
mkdir -p "$DIR"
git -C "$top" archive "$COMMIT" | tar -x -C "$DIR"
[ -f "$DIR/Makefile" ] || { echo "build_anchor: git archive of $COMMIT produced no Makefile" >&2; exit 2; }
if ! make -C "$DIR" build > "$DIR.log" 2>&1; then
    echo "build_anchor: make failed, see $DIR.log" >&2
    exit 2
fi
bin=$DIR/build/release/eigenscript
sha=$(sha256sum "$bin" | cut -d' ' -f1)
recipe=$(sha256sum "$here/build_anchor.sh" | cut -d' ' -f1)
printf '{"tag": "%s", "commit": "%s", "binary": "%s", "binary_sha256": "%s", "recipe_sha256": "%s"}\n' \
    "$TAG" "$COMMIT" "$bin" "$sha" "$recipe" > "$DIR/anchor.json"
echo "anchor: $bin sha256 $sha (recipe $recipe)"
