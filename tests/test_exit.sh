#!/bin/bash
# Regression: `exit of N` requests a clean process exit with code N. It must
# (a) set the exit code, (b) skip code after it, (c) be UNCATCHABLE (a `try`
# must not swallow it), and (d) be leak-clean (it unwinds to main's teardown
# via g_has_error rather than a raw exit(), so ASan sees no leak — this runs in
# the ASan suite too). `exit` was dropped in v0.19.0; tidelog/liferaft use it.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$TESTS_DIR/.." && pwd)/src/eigenscript"

check_exit() {
    local name="$1" prog="$2" want_code="$3" want_out="$4"
    local f; f=$(mktemp /tmp/eigs_exit_XXXXXX.eigs)
    printf '%s\n' "$prog" > "$f"
    local out; out=$("$BIN" "$f" 2>&1); local rc=$?
    rm -f "$f"
    if [ "$rc" = "$want_code" ] && [ "$out" = "$want_out" ]; then
        echo "  PASS: $name (rc=$rc)"
    else
        echo "  FAIL: $name (rc=$rc want=$want_code | out='$out' want='$want_out')"
    fi
}

# A worker exit must interrupt the main thread, including every blocking
# concurrency primitive.  Bound these rows without coreutils `timeout`, which
# is absent on the macOS runners.
check_worker_exit() {
    local name="$1" prog="$2" want_out="$3"
    local f out_file rc pid i
    f=$(mktemp /tmp/eigs_worker_exit_XXXXXX.eigs)
    out_file=$(mktemp /tmp/eigs_worker_exit_out_XXXXXX)
    printf '%s\n' "$prog" > "$f"
    "$BIN" "$f" >"$out_file" 2>&1 &
    pid=$!
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 200 ]; do
        sleep 0.05
        i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        rc=124
    else
        wait "$pid"; rc=$?
    fi
    local out; out=$(cat "$out_file")
    rm -f "$f" "$out_file"
    if [ "$rc" = 5 ] && [ "$out" = "$want_out" ]; then
        echo "  PASS: $name (rc=$rc)"
    else
        echo "  FAIL: $name (rc=$rc want=5 | out='$out' want='$want_out')"
    fi
}

check_exit "exit of 1 sets code, skips code after" 'print of "x"
exit of 1
print of "y"' 1 "x"
check_exit "exit of 0" 'exit of 0' 0 ""
check_exit "exit of 42" 'exit of 42' 42 ""
check_exit "exit is uncatchable (try does not swallow it)" 'try:
    exit of 5
catch e:
    print of "caught"
print of "after-try"' 5 ""
check_exit "exit unwinds out of a function and loop" 'define f() as:
    loop while 1 == 1:
        exit of 7
f of null
print of "no"' 7 ""

# #739/#1149: `exit of N` inside a worker stops the state and decides its code.
check_exit "exit inside a spawned worker stops main" 'define worker(n) as:
    exit of 9
    return 1
w is spawn of [worker, 1]
r is thread_join of w
print of "MARK_END"' 9 ""

# #1149: exit in any worker is a state-wide stop request.  It wakes blocked
# builtins and the VM dispatch check stops CPU-bound main code before MARK_END.
check_worker_exit "worker exit interrupts main recv" 'ch is channel of 1
define quitter() as:
    usleep of 20000
    exit of 5
spawn of quitter
recv of ch
print of "MARK_END"' ""

check_worker_exit "worker exit interrupts main recv_timeout" 'ch is channel of 1
define quitter() as:
    usleep of 20000
    exit of 5
spawn of quitter
recv_timeout of [ch, 60000]
print of "MARK_END"' ""

check_worker_exit "worker exit interrupts main usleep" 'define quitter() as:
    usleep of 20000
    exit of 5
spawn of quitter
usleep of 60000000
print of "MARK_END"' ""

check_worker_exit "worker exit interrupts main thread_join" 'define sleeper() as:
    usleep of 60000000
    return 1
define quitter() as:
    usleep of 20000
    exit of 5
slow is spawn of sleeper
spawn of quitter
thread_join of slow
print of "MARK_END"' ""

check_worker_exit "worker exit interrupts busy main" 'define quitter() as:
    usleep of 20000
    exit of 5
spawn of quitter
i is 0
loop while i < 1000000000:
    i is i + 1
print of "MARK_END"' ""

# The loop starts single-threaded and enters an OSR thunk before spawn turns
# multithreading on. Native back-edges must notice the worker's exit too.
check_worker_exit "worker exit interrupts an already-running JIT loop" 'define quitter() as:
    exit of 5
i is 0
loop while i < 1000000000:
    i is i + 1
    if i == 10000:
        spawn of quitter
print of "MARK_END"' ""

echo ""
