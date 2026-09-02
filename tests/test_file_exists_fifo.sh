#!/usr/bin/env bash
# #1070: file_exists was an fopen probe, and fopen on a reader-less fifo
# BLOCKS -- the program hung with no diagnostic. It is a stat probe now. Runs
# with cwd src/ like every child script. Prints PASS:/FAIL: lines.
EIGS="${EIGS:-./eigenscript}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkfifo "$T/pipe" || { echo "FAIL: mkfifo unavailable"; exit 1; }
: > "$T/reg"; mkdir "$T/dir"
printf 'print of (file_exists of "%s")\nprint of (file_exists of "%s")\nprint of (file_exists of "%s")\nprint of (file_exists of "%s/missing")\nprint of (is_file of "%s")\n' "$T/pipe" "$T/reg" "$T/dir" "$T" "$T/pipe" > "$T/p.eigs"
out=$(timeout 5 "$EIGS" "$T/p.eigs" 2>&1); rc=$?
if [ "$rc" -eq 124 ]; then echo "FAIL: file_exists on a reader-less fifo BLOCKED (rc 124)"; exit 1; fi
want=$'1\n1\n1\n0\n0'
if [ "$out" = "$want" ]; then
    echo "PASS: file_exists answers fifo=1 file=1 dir=1 missing=0 without blocking; is_file(fifo)=0"
else
    echo "FAIL: file_exists probe: rc=$rc out=$(echo "$out" | tr '\n' '|') want=$(echo "$want" | tr '\n' '|')"; exit 1
fi
