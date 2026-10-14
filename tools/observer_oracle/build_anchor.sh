#!/bin/bash
# Build the observer oracle's floor anchor (#1758): EigenScript v0.46.0 (commit
# 4a3a5c19), the Makefile's release target (`make build`, one job), from the
# tag's own files (git archive), so nothing in this checkout but the tag
# reaches the build. The anchor lives in
# ${XDG_CACHE_HOME:-$HOME/.cache}/eigs-oracle-anchor/<sha256 of this recipe>/
# and is built under an exclusive flock; score.py holds the same lock shared
# while it measures, so no worktree's build deletes a binary another is
# measuring. A valid anchor already there is kept. The anchor's identity is
# this recipe plus the verdict list score.py re-measures on it; the binary's
# sha256 is recorded for information only (another toolchain builds other
# bytes). score.py --write-floor accepts only the binary this recipe stamped
# on this machine.
# usage: bash tools/observer_oracle/build_anchor.sh   (prints the stamp)
set -euo pipefail
TAG=v0.46.0
COMMIT=4a3a5c1941568e9bc562c7c8221cff22dc8ba697
here=$(cd "$(dirname "$0")" && pwd)
recipe=$(sha256sum "$here/build_anchor.sh" | cut -d' ' -f1)
root=${XDG_CACHE_HOME:-$HOME/.cache}/eigs-oracle-anchor
DIR=$root/$recipe
bin=$DIR/build/release/eigenscript
top=$(git -C "$here" rev-parse --show-toplevel)  # git archive from a subdirectory archives only it
if [ "$(git -C "$top" rev-parse "$TAG^{commit}")" != "$COMMIT" ]; then
    echo "build_anchor: tag $TAG is not commit $COMMIT" >&2
    exit 2
fi
mkdir -p "$root"
exec 9>"$DIR.lock"
flock -x 9
if [ -x "$bin" ] && [ -f "$DIR/anchor.json" ] \
        && grep -q "\"binary_sha256\": \"$(sha256sum "$bin" | cut -d' ' -f1)\"" "$DIR/anchor.json"; then
    cat "$DIR/anchor.json"
    exit 0
fi
rm -rf "$DIR"
mkdir -p "$DIR"
git -C "$top" archive "$COMMIT" | tar -x -C "$DIR"
[ -f "$DIR/Makefile" ] || { echo "build_anchor: git archive of $COMMIT produced no Makefile" >&2; exit 2; }
if ! make -C "$DIR" build > "$DIR.log" 2>&1; then
    echo "build_anchor: make failed, see $DIR.log" >&2
    exit 2
fi
sha=$(sha256sum "$bin" | cut -d' ' -f1)
tool=$( (readelf -p .comment "$bin" 2>/dev/null || true) | sed -n 's/^ *\[ *[0-9a-f]*\] *//p' | head -1 | tr -d '"\\')
printf '{"tag": "%s", "commit": "%s", "binary": "%s", "binary_sha256": "%s", "recipe_sha256": "%s", "toolchain": "%s"}\n' \
    "$TAG" "$COMMIT" "$bin" "$sha" "$recipe" "$tool" > "$DIR/anchor.json"
cat "$DIR/anchor.json"
