#!/usr/bin/env bash
# Focused harness controls; no EigenScript binary/build required.
set -u
case "${1:-}" in ''|--no-cleanup-deferral) ;; *) exit 2;; esac
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/sigusr1_support.sh"
TMP=$(mktemp -d)
PIDS=""; EXTRA_PID=""
cleanup() {
    local status=$? p
    trap '' INT TERM HUP
    trap - EXIT
    for p in $PIDS; do sigusr1_stop "$p" || status=1; done
    if [ -n "$EXTRA_PID" ]; then kill -KILL "$EXTRA_PID" 2>/dev/null || true; fi
    rm -rf "$TMP"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
checks=0
check() { if ! "$@"; then echo "FAIL: portability control $*" >&2; exit 1; fi; checks=$((checks+1)); }

# Restrict the fake sed seam to the actual GNU/BSD CLI distinction. Actual
# BSD sed/Bash3 execution remains a separate macOS validation requirement.
sed() { [ "$1" != '-i' ] || return 1; command sed "$@"; }
printf '%s\n' '@SENT1@' > "$TMP/fixture"
check sigusr1_replace_sentinel "$TMP/fixture" '@SENT1@' "$TMP/ready"
check test "$(cat "$TMP/fixture")" = "$TMP/ready"
check test ! -e "$TMP/fixture.bak"
# Original invocation must be rejected by the same seam, leaving placeholder.
printf '%s\n' '@SENT1@' > "$TMP/old"
if sed -i "s|@SENT1@|$TMP/ready|" "$TMP/old"; then exit 1; fi
check test "$(cat "$TMP/old")" = '@SENT1@'
# A substitution tool that succeeds without replacing anything is rejected.
if ( sed() { return 0; }; sigusr1_replace_sentinel "$TMP/old" '@SENT1@' "$TMP/ready" ) > "$TMP/retained.out" 2>&1; then exit 1; fi
check grep -qF 'FAIL: sigusr1: sentinel placeholder remains' "$TMP/retained.out"

# Test the real strict EXIT helper and initializer without executing its gate.
awk '/^_sd_main_depth=/{print} /^_sd_exit\(\)/{copy=1} copy{print} copy && /^}/{exit}' "$TESTS_DIR/../tools/strict_differential.sh" > "$TMP/strict-helper"
if ! (
    unset BASHPID
    TMP="$TMP/strict-parent"; mkdir "$TMP"
    verdict_printed=1
    . "${TMP%/strict-parent}/strict-helper"
    ( _sd_exit )
    [ -d "$TMP" ] || exit 41
    _sd_exit
    [ ! -e "$TMP" ] || exit 42
); then echo 'FAIL: strict subshell cleanup ownership' >&2; exit 1; fi
checks=$((checks+1))
# A $$-only substitute must fail the same parent-directory witness.
command sed 's/"$BASH_SUBSHELL" = "${_sd_main_depth:-}"/"$$" = "$$"/' "$TMP/strict-helper" > "$TMP/wrong-helper"
(
    TMP="$TMP/wrong-parent"; mkdir "$TMP"; verdict_printed=1
    . "${TMP%/wrong-parent}/wrong-helper"
    ( _sd_exit )
    [ -d "$TMP" ] || exit 41
) > "$TMP/wrong.out" 2>&1
rc=$?
check test "$rc" -eq 41
# Restore the original Bash-only variable requirement: nounset must reject it
# under the same missing-variable condition captured by the macOS CI log.
if ( unset BASHPID; eval '_sd_main_pid=$BASHPID' ) > "$TMP/old-bash.out" 2>&1; then exit 1; fi
check grep -qF 'BASHPID' "$TMP/old-bash.out"

# Invoke the actual ledger helper with padded, unpadded and invalid wc output.
awk '/^ledger_count\(\)/{copy=1} copy{print} copy && /^}/{exit}' "$TESTS_DIR/../tools/replay_diff.sh" > "$TMP/count-helper"
. "$TMP/count-helper"
: > "$TMP/ledger"
wc() { printf '       0\n'; }
check test "$(ledger_count "$TMP/ledger")" = 0
wc() { printf '7\n'; }
check test "$(ledger_count "$TMP/ledger")" = 7
wc() { printf 'garbage\n'; }
if ledger_count "$TMP/ledger" > "$TMP/invalid-count"; then exit 1; fi
check test ! -s "$TMP/invalid-count"
wc() { return 1; }
if ledger_count "$TMP/ledger" > "$TMP/failed-count"; then exit 1; fi
check test ! -s "$TMP/failed-count"

# Direct owned child: normal wait preserves the real nonzero status.
python3 -c 'raise SystemExit(7)' &
PID=$!; PIDS="$PID"
sigusr1_wait "$PID" 20; rc=$?
check test "$rc" -eq 7
PIDS=""
# A DONE marker does not mean exit; ignore TERM so KILL is exercised too.
: > "$TMP/done"
python3 -c 'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print("DONE",flush=True); time.sleep(60)' > "$TMP/done" &
PID=$!; PIDS="$PID"
for ((i=0; i<50; i++)); do grep -q '^DONE$' "$TMP/done" && break; sleep 0.1; done
check grep -q '^DONE$' "$TMP/done"
sigusr1_wait "$PID" 1 > "$TMP/wait.out" 2>&1; rc=$?
check test "$rc" -eq 124
check grep -qF 'FAIL: sigusr1: child did not exit after DONE' "$TMP/wait.out"
if sigusr1_running "$PID"; then echo 'FAIL: owned child remains live' >&2; exit 1; fi
checks=$((checks+1)); PIDS=""
# Source-derived successful labels: choose the clean task exit and deduplicate
# its two existing source branches. These are helper fixtures, not VM results.
awk '/^[ ]*pass "/ { sub(/^[ ]*pass "/,"PASS: "); sub(/"$/,""); if (!seen[$0]++) print }' "$TESTS_DIR/test_sigusr1_dump.sh" |
    grep -v 'LeakSanitizer nonzero exit' > "$TMP/closed-result"
closed_output=$(cat "$TMP/closed-result")
check sigusr1_result_check "$closed_output" 0
open_output=$(grep -vE 'gated first dump declares|second dump arrived after' "$TMP/closed-result")
check sigusr1_result_check "$open_output" 0
for mode in empty early badrc; do
    case "$mode" in
        empty) output=""; status=0; witness='missing/duplicate assertion' ;;
        early) output='PASS: sigusr1: child reached its loop (READY barrier)'; status=0; witness='missing/duplicate assertion' ;;
        badrc) output="$closed_output"; status=1; witness='child exit 1' ;;
    esac
    if sigusr1_result_check "$output" "$status" > "$TMP/consume-$mode" 2>&1; then exit 1; fi
    check grep -qF "$witness" "$TMP/consume-$mode"
done
# Exercise the actual fixture cleanup after its first signal, then send three
# more signals while the TERM-resistant child is in TERM->KILL cleanup.
control="$TMP/repeated-cleanup.sh"
printf '%s\n' '#!/usr/bin/env bash' 'set -u' '. "$1"' 'DIR=$2' > "$control"
awk '/^cleanup\(\)/{copy=1} copy{print} copy && /^}/{exit}' "$TESTS_DIR/test_sigusr1_dump.sh" >> "$control"
if [ "${1:-}" = '--no-cleanup-deferral' ]; then
    # Mutate only the extracted actual cleanup's one signal-ignore line.
    [ "$(grep -cF "    trap '' INT TERM HUP" "$control")" -eq 1 ] || exit 2
    command sed "/^    trap '' INT TERM HUP$/d" "$control" > "$control.fault"
    mv "$control.fault" "$control"
fi
cat >> "$control" <<'CONTROL'
FIX1="$DIR/a"; FIX2="$DIR/b"; OUT1="$DIR/c"; OUT2="$DIR/d"
ERR1="$DIR/e"; ERR2="$DIR/f"; SENT1="$DIR/g"; SENT2="$DIR/h"
PIDS=""
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
eval "$(declare -f sigusr1_stop | sed '1s/sigusr1_stop/sigusr1_stop_impl/')"
sigusr1_stop() { : > "$DIR/cleaning"; sigusr1_stop_impl "$@"; }
: > "$DIR/ready"
python3 -c 'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print("READY",flush=True); time.sleep(60)' > "$DIR/ready" &
PIDS=$!; printf '%s\n' "$PIDS" > "$DIR/child-pid"
for ((i=0; i<50; i++)); do grep -q '^READY$' "$DIR/ready" && break; sleep 0.1; done
grep -q '^READY$' "$DIR/ready" || { echo 'FAIL: repeated cleanup inner READY missing' >&2; exit 1; }
kill -TERM "$$"
CONTROL
mkdir "$TMP/repeated"
bash "$control" "$TESTS_DIR/sigusr1_support.sh" "$TMP/repeated" > "$TMP/repeated.out" 2>&1 &
PID=$!; PIDS="$PID"
for ((i=0; i<50; i++)); do [ -f "$TMP/repeated/cleaning" ] && break; sleep 0.1; done
if [ -f "$TMP/repeated/child-pid" ]; then EXTRA_PID=$(cat "$TMP/repeated/child-pid"); fi
if [ -z "$EXTRA_PID" ] || ! [ -f "$TMP/repeated/cleaning" ] || ! grep -q '^READY$' "$TMP/repeated/ready"; then
    echo 'FAIL: repeated cleanup barrier missing' >&2; exit 1
fi
checks=$((checks+1))
sent_INT=0; sent_TERM=0; sent_HUP=0; delivery_failed=0
for sig in INT TERM HUP; do
    if kill -"$sig" "$PID"; then
        case "$sig" in INT) sent_INT=1;; TERM) sent_TERM=1;; HUP) sent_HUP=1;; esac
    else delivery_failed=1; fi
done
sigusr1_wait "$PID" 50; rc=$?
if [ "${1:-}" = '--no-cleanup-deferral' ]; then
    matched=0
    case "$rc" in 130) matched=$sent_INT;; 143) matched=$sent_TERM;; 129) matched=$sent_HUP;; esac
    child_state=$(ps -o stat= -p "$EXTRA_PID")
    case "$child_state" in ''|*Z*) child_live=0;; *) child_live=1;; esac
    if [ "$matched" -eq 1 ] && [ "$child_live" -eq 1 ] && kill -0 "$EXTRA_PID" 2>/dev/null; then
        echo 'FAIL: cleanup deferral fault abandoned READY child after delivered signal and matching trap exit' >&2
        exit 1
    fi
    echo "FAIL: cleanup deferral control unattributed (rc=$rc, matched=$matched, live=$child_live, delivery_failed=$delivery_failed)" >&2
    exit 1
fi
if [ "$delivery_failed" -ne 0 ]; then echo 'FAIL: repeated cleanup signal delivery failed' >&2; exit 1; fi
if [ "$rc" -ne 143 ]; then echo "FAIL: repeated cleanup exit: $rc" >&2; exit 1; fi
checks=$((checks+1))
if kill -0 "$EXTRA_PID" 2>/dev/null; then
    kill -KILL "$EXTRA_PID" 2>/dev/null || true
    echo 'FAIL: repeated signal interrupted child cleanup' >&2; exit 1
fi
checks=$((checks+1)); PIDS=""; EXTRA_PID=""
[ "$checks" -eq 25 ] || { echo "FAIL: portability population $checks, expected25" >&2; exit 1; }
echo "ci-portability: checks=$checks failures=0"
