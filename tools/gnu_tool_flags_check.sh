#!/bin/bash
# Reject GNU-only utility flags in tracked shell scripts. Reviewed exceptions
# are count-pinned by path so a second use cannot hide behind an existing row.
set -u
cd "$(dirname "$0")/.." || { echo "gnu-tool-flags: ABORTED: cannot cd" >&2; exit 1; }

PATTERNS=tools/gnu_tool_flags_patterns.txt
ALLOW=tools/gnu_tool_flags_allowlist.txt
FILE_FLOOR=110
[ -f "$PATTERNS" ] && [ -f "$ALLOW" ] || {
    echo "gnu-tool-flags: FAIL: pattern or allowlist data is missing"; exit 1;
}

tmp="${TMPDIR:-/tmp}/gnu_tool_flags.$$"
trap 'rm -f "$tmp" "$tmp.counts"' EXIT HUP INT TERM
: > "$tmp"
files=0
indexed=$(git -c safe.directory='*' ls-files '*.sh') || {
    echo "gnu-tool-flags: FAIL: git could not enumerate tracked *.sh"; exit 1;
}
for file in $indexed; do
    [ -f "$file" ] || continue
    files=$((files + 1))
    awk -v source="$file" -v patterns="$PATTERNS" '
        BEGIN {
            while ((getline row < patterns) > 0) {
                if (row ~ /^#/ || row == "") continue
                tab = index(row, "\t")
                id[++n] = substr(row, 1, tab - 1)
                re[n] = substr(row, tab + 1)
            }
            close(patterns)
        }
        {
            for (i = 1; i <= n; i++)
                if ($0 ~ re[i]) print source "|" id[i] "|" FNR "|" $0
        }
    ' "$file" >> "$tmp"
done
if [ "$files" -lt "$FILE_FLOOR" ]; then
    echo "gnu-tool-flags: FAIL: examined $files tracked *.sh (floor $FILE_FLOOR)"
    exit 1
fi

awk -F '|' '{ count[$1 "|" $2]++ } END { for (key in count) print key "|" count[key] }' "$tmp" > "$tmp.counts"
bad=0; allowed=0
while IFS='|' read -r path id expected reason; do
    case "$path" in ''|'#'*) continue ;; esac
    case "$expected" in ''|*[!0-9]*) echo "gnu-tool-flags: FAIL: malformed allowlist count for $path|$id"; bad=$((bad + 1)); continue ;; esac
    [ -n "$reason" ] || { echo "gnu-tool-flags: FAIL: allowlist entry $path|$id has no reason"; bad=$((bad + 1)); continue; }
    actual=$(awk -F '|' -v key="$path|$id" '$1 "|" $2 == key { print $3 }' "$tmp.counts")
    actual=${actual:-0}
    if [ "$actual" -ne "$expected" ]; then
        echo "gnu-tool-flags: FAIL: $path|$id found $actual time(s), allowlist pins $expected -- $reason"
        bad=$((bad + 1))
    else
        allowed=$((allowed + actual))
    fi
done < "$ALLOW"

while IFS='|' read -r path id count; do
    if ! awk -F '|' -v key="$path|$id" '$1 "|" $2 == key { found=1 } END { exit !found }' "$ALLOW"; then
        echo "gnu-tool-flags: FAIL: unallowlisted GNU-only spelling $path|$id ($count occurrence(s))"
        awk -F '|' -v key="$path|$id" '$1 "|" $2 == key { print "    | " $1 ":" $3 ":" $4 }' "$tmp"
        bad=$((bad + 1))
    fi
done < "$tmp.counts"

if [ "$bad" -ne 0 ]; then
    echo "gnu-tool-flags: FAIL: files=$files allowed-occurrences=$allowed failures=$bad"
    exit 1
fi
echo "gnu-tool-flags: OK: files=$files allowed-occurrences=$allowed failures=0"

if [ "${1:-}" = "--selftest" ]; then
    root=$PWD
    work=$(mktemp -d "$(dirname "$root")/gnu-tool-flags.XXXXXX") || exit 1
    trap 'rm -rf "$work"; rm -f "$tmp" "$tmp.counts"' EXIT HUP INT TERM
    mkdir "$work/repo"
    all="$indexed $PATTERNS $ALLOW"
    copied=links
    for file in $all; do
        mkdir -p "$work/repo/$(dirname "$file")"
        if ! cp -l "$root/$file" "$work/repo/$file" 2>/dev/null; then
            copied=full
            cp "$root/$file" "$work/repo/$file" || { echo "gnu-tool-flags: SELFTEST FAIL: cannot copy $file"; exit 1; }
        fi
    done
    [ "$copied" = links ] || echo "gnu-tool-flags: NOTE: some hard links unavailable; used full copies"
    (cd "$work/repo" && git init -q && git add .) || exit 1
    cp "$work/repo/tools/jit_diff.sh" "$work/planted" || exit 1
    plant=$(printf 'realpath \055\155 /tmp # issue 1433 plant')
    printf '\n%s\n' "$plant" >> "$work/planted"
    mv "$work/planted" "$work/repo/tools/jit_diff.sh" || exit 1
    if (cd "$work/repo" && bash tools/gnu_tool_flags_check.sh) > "$work/plant.log" 2>&1; then
        echo "gnu-tool-flags: SELFTEST FAIL: realpath-m plant passed"
        cat "$work/plant.log"
        exit 1
    fi
    echo "gnu-tool-flags: selftest OK: realpath-m plant turned the gate red"
fi
