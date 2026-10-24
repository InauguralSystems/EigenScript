#!/bin/sh
# Hold this tree's build lock for one make process (#1940). The Makefile runs
#   $(shell sh tools/tree_lock.sh <tree-root> $$PPID)
# while it parses: a holder takes <tree-root>/.make.lock with flock(1) and keeps
# it until that make process exits. make itself is not re-run, so -f, -q, -n,
# MAKELEVEL and the goal list behave exactly as in an unlocked make. Without
# flock(1) (macOS), it does nothing.
root=$1 pid=$2
command -v flock >/dev/null 2>&1 || exit 0
lock="$root/.make.lock"
ready=$(mktemp "${TMPDIR:-/tmp}/eigs-tree-lock.XXXXXX") || exit 0
rm -f "$ready"
if ! flock -n "$lock" true 2>/dev/null; then
    echo "make: waiting for the build lock (another make in this tree)" >&2
fi
# The holder's stdio must not be make's $(shell) pipe, or make waits for EOF.
flock "$lock" sh -c ': >"$1"; while kill -0 "$2" 2>/dev/null; do sleep 0.2; done' \
    sh "$ready" "$pid" </dev/null >/dev/null 2>&1 &
holder=$!
while [ ! -e "$ready" ]; do
    if ! kill -0 "$holder" 2>/dev/null; then
        echo "make: could not take the build lock ($lock); building unlocked" >&2
        exit 0
    fi
    sleep 0.05
done
rm -f "$ready"
