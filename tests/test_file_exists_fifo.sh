#!/usr/bin/env bash
# #1070: file_exists was an fopen probe, and fopen on a reader-less fifo
# BLOCKS -- the program hung with no diagnostic. It is a stat probe now. Runs
# with cwd src/ like every child script. Prints PASS:/FAIL: lines.
#
# The time limit is pure shell: macOS runners have no `timeout` (the first
# version's `timeout 5` died rc 127 there and the section was flagged
# untrustworthy, correctly). Background the run, poll, kill at the deadline.
EIGS="${EIGS:-./eigenscript}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkfifo "$T/pipe" || { echo "FAIL: mkfifo unavailable"; exit 1; }
: > "$T/reg"; mkdir "$T/dir"
printf 'print of (file_exists of "%s")\nprint of (file_exists of "%s")\nprint of (file_exists of "%s")\nprint of (file_exists of "%s/missing")\nprint of (is_file of "%s")\n' "$T/pipe" "$T/reg" "$T/dir" "$T" "$T/pipe" > "$T/p.eigs"
"$EIGS" "$T/p.eigs" > "$T/out" 2>&1 &
pid=$!
rc=""
for i in $(seq 1 50); do
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; rc=$?; break; fi
    sleep 0.1
done
if [ -z "$rc" ]; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; echo "FAIL: file_exists on a reader-less fifo BLOCKED (killed after 5s)"; exit 1; fi
out=$(cat "$T/out")
want=$'1\n1\n1\n0\n0'
if [ "$rc" -eq 0 ] && [ "$out" = "$want" ]; then
    echo "PASS: file_exists answers fifo=1 file=1 dir=1 missing=0 without blocking; is_file(fifo)=0"
else
    echo "FAIL: file_exists probe: rc=$rc out=$(echo "$out" | tr '\n' '|') want=$(echo "$want" | tr '\n' '|')"; exit 1
fi
