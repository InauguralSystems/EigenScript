#!/bin/bash
# Count consumer files that refer to each registered EigenScript builtin.
# Each consumer is searched at its fetched remote default branch (origin/HEAD,
# falling back to origin/main), not its possibly stale local working tree.
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
    ref=$(git -C "$checkout" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    if [ -z "$ref" ]; then
        ref=origin/main
    fi
    if ! git -C "$checkout" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
        echo "$0: $checkout has no fetched $ref" >&2
        exit 1
    fi
    printf '%s|%s\n' "$checkout" "$ref"
done > "$TMP_FILES"
while IFS= read -r name; do
    count=0
    while IFS='|' read -r checkout ref; do
        matches=$(git -C "$checkout" grep -lw -e "$name" "$ref" -- '*.eigs' \
            ':(exclude)tests/**' ':(exclude)test/**' ':(exclude)test*/**' \
            ':(exclude)examples/**' ':(exclude)vendor/**' ':(exclude)vendored/**' \
            ':(exclude)third_party/**' ':(exclude)EigenScript/**' 2>/dev/null || true)
        if [ -n "$matches" ]; then
            files=$(printf '%s\n' "$matches" | wc -l | tr -d ' ')
            count=$((count + files))
        fi
    done < "$TMP_FILES"
    printf '%d %s\n' "$count" "$name"
done < "$TMP_NAMES"
