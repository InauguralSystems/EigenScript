#!/bin/sh
# Hold this tree's build lock for one make process (#1940). The Makefile runs
#   $(shell sh tools/tree_lock.sh <tree-root> $$PPID)
# while it parses. A holder takes <tree-root>/.make.lock with flock(1) and
# keeps it until that make process exits. make itself is never re-run, so -f,
# -q, -n, -o, -W, MAKELEVEL and the goals behave exactly as in an unlocked make.
# The holder runs in its own session (setsid): it is the build system's, not a
# process the make leaves behind, and session-owning harnesses
# (tools/bounded_process.py) would otherwise see it outlive make by one poll.
# Without flock(1) or setsid(1) (macOS), it does nothing.
if [ "${1:-}" = hold ]; then
    # hold LOCK READY PID [try]: take the lock, signal READY, release when PID exits.
    exec 9>"$2" || { : >"$3.fail"; exit 1; }
    if [ "${5:-}" = try ]; then
        flock -n 9 || { : >"$3.busy"; exit 75; }
    else
        flock 9 || { : >"$3.fail"; exit 1; }
    fi
    : >"$3"
    while kill -0 "$4" 2>/dev/null; do sleep 0.05; done
    exit 0
fi
try=
if [ "${1:-}" = --try ]; then
    [ "$#" -eq 3 ] || { echo "usage: tools/tree_lock.sh [--try] TREE_ROOT PID" >&2; exit 2; }
    try=try
    shift
else
    [ "$#" -eq 2 ] || { echo "usage: tools/tree_lock.sh [--try] TREE_ROOT PID" >&2; exit 2; }
fi
root=$1 pid=$2
command -v flock >/dev/null 2>&1 && command -v setsid >/dev/null 2>&1 || exit 0
lock="$root/.make.lock"
ready=$(mktemp "${TMPDIR:-/tmp}/eigs-tree-lock.XXXXXX") || exit 0
rm -f "$ready"
# Stay quiet for a moment: the previous make's holder can still be on its
# last poll. A try-lock must not spend even this grace period waiting.
if [ -z "$try" ] && ! flock -w 0.5 "$lock" true 2>/dev/null; then
    echo "make: waiting for the build lock (another make in this tree)" >&2
fi
# The holder's stdio must not be make's $(shell) pipe, or make waits for EOF.
setsid sh "$0" hold "$lock" "$ready" "$pid" "$try" </dev/null >/dev/null 2>&1 &
while [ ! -e "$ready" ]; do
    if [ -e "$ready.busy" ]; then
        rm -f "$ready.busy"
        exit 75
    fi
    if [ -e "$ready.fail" ]; then
        rm -f "$ready.fail"
        echo "make: could not take the build lock ($lock); building unlocked" >&2
        exit 0
    fi
    sleep 0.02
done
rm -f "$ready"
