#!/bin/bash
# Count consumer files that refer to each registered EigenScript builtin.
# Usage: tools/builtin_usage.sh DIRECTORY [DIRECTORY ...]
set -eu
if [ "$#" -eq 0 ]; then
    echo "usage: $0 DIRECTORY [DIRECTORY ...]" >&2
    exit 2
fi
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP_NAMES=$(mktemp)
TMP_FILES=$(mktemp)
trap 'rm -f "$TMP_NAMES" "$TMP_FILES"' EXIT HUP INT TERM
sed -n 's/.*env_set_local_owned(env, "\([A-Za-z_][A-Za-z0-9_]*\)", make_builtin.*/\1/p' "$ROOT"/src/*.c | LC_ALL=C sort -u > "$TMP_NAMES"
for checkout do
    find "$checkout" -type f \
        ! -path '*/.git/*' \
        ! -path '*/tests/*' ! -path '*/test/*' ! -path '*/test*/*' \
        ! -path '*/examples/*' \
        ! -path '*/vendor/*' ! -path '*/vendored/*' ! -path '*/third_party/*' \
        ! -path '*/EigenScript/*' -print
 done > "$TMP_FILES"
while IFS= read -r name; do
    count=0
    while IFS= read -r file; do
        if LC_ALL=C grep -Eq "(^|[^A-Za-z0-9_])${name}([^A-Za-z0-9_]|$)" "$file" 2>/dev/null; then
            count=$((count + 1))
        fi
    done < "$TMP_FILES"
    printf '%d %s\n' "$count" "$name"
done < "$TMP_NAMES"
