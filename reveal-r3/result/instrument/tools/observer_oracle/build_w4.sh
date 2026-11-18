#!/bin/bash
# Build a Round 3 runtime arm by recipe (#1758, Deviation D10): EigenScript at commit SHA, the Makefile's release
# target (`make build`, one job), from that commit's own files (git archive), so nothing in this checkout but the
# commit reaches the build. The arm lives in
# ${XDG_CACHE_HOME:-$HOME/.cache}/eigs-oracle-w4/<sha256 of this recipe>/<SHA>/ beside its stamp arm.json:
# {source_sha, recipe_id, binary, binary_sha256, toolchain, cc}. recipe_id is the sha256 of this file, so an arm is
# identified across machines by (source_sha, recipe_id); its binary sha256 is information (another toolchain
# builds other bytes). judge.py reads the stamp beside a binary to seal and verify a manifest.
# W4: INC plus exactly OBSERVER_WINDOW_N 10 -> 4 in src/eigenscript.h.
# usage: bash tools/observer_oracle/build_w4.sh   (prints the stamp)
set -euo pipefail
[ $# -eq 0 ] || { echo "usage: build_w4.sh" >&2; exit 2; }
set -- 3d8a14b4
here=$(cd "$(dirname "$0")" && pwd)
top=$(git -C "$here" rev-parse --show-toplevel)
sha=$(git -C "$top" rev-parse --verify "$1^{commit}") || { echo "build_arm: $1 is not a commit here" >&2; exit 2; }
recipe=$(sha256sum "$here/build_w4.sh" | cut -d' ' -f1)
root=${XDG_CACHE_HOME:-$HOME/.cache}/eigs-oracle-w4/$recipe
DIR=$root/$sha
bin=$DIR/build/release/eigenscript
mkdir -p "$root"
exec 9>"$DIR.lock"
flock -x 9
if [ -x "$bin" ] && [ -f "$DIR/arm.json" ] \
        && grep -q "\"binary_sha256\": \"$(sha256sum "$bin" | cut -d' ' -f1)\"" "$DIR/arm.json"; then
    cat "$DIR/arm.json"
    exit 0
fi
rm -rf "$DIR"
mkdir -p "$DIR"
git -C "$top" archive "$sha" | tar -x -C "$DIR"
[ -f "$DIR/Makefile" ] || { echo "build_arm: git archive of $sha produced no Makefile" >&2; exit 2; }
python3 - "$DIR/src/eigenscript.h" <<'PATCH'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = '#define OBSERVER_WINDOW_N 10'
assert s.count(old) == 1, 'W4: expected exactly one window definition'
p.write_text(s.replace(old, '#define OBSERVER_WINDOW_N 4'))
PATCH
# The build runs under a sanitized environment, as the observer-anchor Makefile target runs build_anchor.sh
# (env -i HOME PATH=/usr/bin:/bin): no MAKEFLAGS, CFLAGS, CC or other caller override reaches it (R30I-4 item 5).
if ! env -i HOME="$HOME" PATH=/usr/bin:/bin LANG=C make -C "$DIR" build > "$DIR.log" 2>&1; then
    echo "build_arm: make failed, see $DIR.log" >&2
    exit 2
fi
bsha=$(sha256sum "$bin" | cut -d' ' -f1)
tool=$( (readelf -p .comment "$bin" 2>/dev/null || true) | sed -n 's/^ *\[ *[0-9a-f]*\] *//p' | head -1 | tr -d '"\\')
cc=$(env -i PATH=/usr/bin:/bin cc --version 2>/dev/null | head -1 | tr -d '"\\')
printf '{"source_sha": "%s", "recipe_id": "%s", "binary": "%s", "binary_sha256": "%s", "toolchain": "%s", "cc": "%s"}\n' \
    "$sha" "$recipe" "$bin" "$bsha" "$tool" "$cc" > "$DIR/arm.json"
cat "$DIR/arm.json"
