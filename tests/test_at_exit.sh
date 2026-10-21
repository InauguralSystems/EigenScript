#!/bin/bash
# Runtime contract checks for `at_exit` (#1839).
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="${EIGS:-$TESTS_DIR/../src/eigenscript}"
PASS=0
FAIL=0
WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs-at-exit.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT

check_case() {
    name=$1 want=$2 file=$3 marker=${4:-}
    out=$($EIGS "$file" 2>&1); rc=$?
    if [ "$rc" -eq "$want" ] && { [ -z "$marker" ] || grep -qF "$marker" <<<"$out"; }; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name rc=$rc wanted=$want"
        printf '%s\n' "$out"
        FAIL=$((FAIL + 1))
    fi
}

out=$($EIGS "$TESTS_DIR/at_exit_concurrent.eigs" 2>&1)
rc=$?
bad=0
for i in $(seq 0 23); do
    count=$(grep -cFx "AT_EXIT_WORKER $i" <<<"$out" || true)
    [ "$count" -eq 1 ] || bad=1
done
lines=$(grep -c '^AT_EXIT_WORKER ' <<<"$out" || true)
if [ "$rc" -eq 0 ] && [ "$bad" -eq 0 ] && [ "$lines" -eq 24 ]; then
    echo "  PASS: concurrent registrations each ran exactly once"
    PASS=$((PASS + 1))
else
    echo "  FAIL: concurrent registrations rc=$rc hook-lines=$lines"
    FAIL=$((FAIL + 1))
fi

# The no-argument path is a distinct main() branch.  EOF must run callbacks
# before the persistent REPL global is destroyed (interactive and piped share
# this teardown).
cat >"$WORK/repl.in" <<'EOF'
define repl_hook() as:
    print of "AT_EXIT REPL RAN"

at_exit of repl_hook
EOF
out=$($EIGS <"$WORK/repl.in" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -cFx 'AT_EXIT REPL RAN' <<<"$out" || true)" -eq 1 ]; then
    echo "  PASS: piped REPL runs callbacks"
    PASS=$((PASS + 1))
else
    echo "  FAIL: piped REPL callback rc=$rc"
    printf '%s\n' "$out"
    FAIL=$((FAIL + 1))
fi

cat >"$WORK/worker-exit.eigs" <<'EOF'
define hook() as:
    print of "AT_EXIT WORKER EXIT RAN"
at_exit of hook
define worker() as:
    exit of 7
h is spawn of worker
thread_join of h
EOF
check_case "worker exit is suspended while callback runs" 7 "$WORK/worker-exit.eigs" "AT_EXIT WORKER EXIT RAN"

cat >"$WORK/handles.eigs" <<'EOF'
kept is channel of 2
send of [kept, "kept value"]
define hook() as:
    print of recv of kept
    made is channel of 2
    send of [made, "made value"]
    print of recv of made
at_exit of hook
EOF
check_case "callbacks can use retained and newly-created handles" 0 "$WORK/handles.eigs" "made value"

# Status precedence table: a program failure wins; otherwise a nonzero hook
# exit wins, then a hook error, then success.  These are separate processes so
# no row can accidentally inherit another row's state.
cat >"$WORK/throw-exit-zero.eigs" <<'EOF'
define hook() as:
    exit of 0
at_exit of hook
throw of "ORIGINAL FAILURE"
EOF
check_case "callback exit zero cannot green an uncaught error" 1 "$WORK/throw-exit-zero.eigs" "ORIGINAL FAILURE"

cat >"$WORK/program-exit.eigs" <<'EOF'
define hook() as:
    exit of 3
at_exit of hook
exit of 6
EOF
check_case "nonzero program exit outranks callback exit" 6 "$WORK/program-exit.eigs"

cat >"$WORK/hook-exit.eigs" <<'EOF'
define hook() as:
    exit of 9
at_exit of hook
EOF
check_case "nonzero callback exit decides successful run" 9 "$WORK/hook-exit.eigs"

cat >"$WORK/hook-error.eigs" <<'EOF'
define hook() as:
    throw of "HOOK FAILURE"
at_exit of hook
EOF
check_case "callback error makes successful run fail" 1 "$WORK/hook-error.eigs" "HOOK FAILURE"

cat >"$WORK/hook-zero.eigs" <<'EOF'
define hook() as:
    exit of 0
at_exit of hook
EOF
check_case "callback exit zero preserves success" 0 "$WORK/hook-zero.eigs"

out=$($EIGS "$TESTS_DIR/at_exit_continue.eigs" 2>&1)
rc=$?
first=$(grep -cFx 'AT_EXIT FIRST RAN' <<<"$out" || true)
third=$(grep -cFx 'AT_EXIT THIRD RAN' <<<"$out" || true)
middle_err=$(grep -c 'AT_EXIT MIDDLE ERROR' <<<"$out" || true)
third_err=$(grep -c 'AT_EXIT THIRD ERROR' <<<"$out" || true)
if [ "$rc" -eq 1 ] && [ "$first" -eq 1 ] && [ "$third" -eq 1 ] && \
   [ "$middle_err" -ge 1 ] && [ "$third_err" -ge 1 ]; then
    echo "  PASS: callback errors reported and remaining callbacks ran"
    PASS=$((PASS + 1))
else
    echo "  FAIL: callback continuation rc=$rc first=$first third=$third middle-errors=$middle_err third-errors=$third_err"
    printf '%s\n' "$out"
    FAIL=$((FAIL + 1))
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
