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

echo ""
