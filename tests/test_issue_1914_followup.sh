#!/usr/bin/env bash
echo "PLAN: 5"
# Focused regressions for the remaining side-effect-free replay follow-ups.
set -u
EIGS="${EIGS:-$(cd "$(dirname "$0")/.." && pwd)/src/eigenscript}"
T=$(mktemp -d "${TMPDIR:-/tmp}/eigs-1914.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1 ($2)"; fail=$((fail + 1)); }

# 1: after the trace cap raises, import must not compile or execute the module.
python3 - "$T/huge.eigs" <<'PY'
import sys
with open(sys.argv[1], "w") as f:
    f.write("#" + "x" * (10 * 1024 * 1024) + "\nx is (\n")
PY
printf 'import huge\nprint of "AFTER"\n' > "$T/import.eigs"
(cd "$T" && EIGS_TRACE=import.tape "$EIGS" import.eigs >import.out 2>import.err); rc=$?
if [ "$rc" -ne 0 ] && grep -q 'over the 10485760-byte trace cap' "$T/import.err" \
   && ! grep -q 'Parse error' "$T/import.err" && ! grep -q 'AFTER' "$T/import.out"; then
    ok "oversized traced import stops at the recording failure"
else bad "oversized import" "rc=$rc out=$(cat "$T/import.out") err=$(cat "$T/import.err")"; fi

# 2: only a string digest or the exact one-string error list is legal.
printf 'try:\n    print of (md5_file of "never-open")\ncatch e:\n    print of e\n' > "$T/md5.eigs"
vh=$(head -1 "$T/import.tape")
shape_ok=1
for shape in '[]' '[1]' '["a", "b"]' '"x"' '"0123456789abcdef0123456789abcdeF"' '"0123456789abcdef0123456789abcdef0"'; do
    printf '%s\nB 0 1 1 0 root -\nN 0 md5_file=%s\n' "$vh" "$shape" > "$T/md5.tape"
    out=$(EIGS_REPLAY="$T/md5.tape" "$EIGS" "$T/md5.eigs" 2>&1)
    echo "$out" | grep -q 'md5_file: recorded result has invalid replay shape' || shape_ok=0
done
[ "$shape_ok" -eq 1 ] && ok "malformed md5_file results are refused" || bad "md5_file shapes" "one was accepted"

# 4: changing the host clock cannot change a replayed SDL tick value.
printf 'print of (gfx_ticks of null)\n' > "$T/ticks.eigs"
EIGS_TRACE="$T/ticks.tape" "$EIGS" "$T/ticks.eigs" > "$T/ticks.record"
sleep 1
EIGS_REPLAY="$T/ticks.tape" "$EIGS" "$T/ticks.eigs" > "$T/ticks.replay"
if cmp -s "$T/ticks.record" "$T/ticks.replay" && grep -q ' gfx_ticks=' "$T/ticks.tape"; then
    ok "gfx_ticks is tape-served"
else bad "gfx_ticks tape" "record=$(cat "$T/ticks.record") replay=$(cat "$T/ticks.replay")"; fi

# 5: sleep_orders_spawned_output -- waits must remain live so they continue to
# order observable worker output.  The 550 ms margin gives a loaded runner ample
# time to start both workers before the slow worker is eligible to print.
cat > "$T/sleep.eigs" <<'EOF'
define slow() as:
    usleep of 600000
    print of "slow"
define fast() as:
    usleep of 50000
    print of "fast"
slow_handle is spawn of slow
fast_handle is spawn of fast
thread_join of slow_handle
thread_join of fast_handle
EOF
EIGS_TRACE="$T/sleep.tape" "$EIGS" "$T/sleep.eigs" > "$T/sleep.record"
sleep_ok=1
[ "$(cat "$T/sleep.record")" = $'fast\nslow' ] || sleep_ok=0
for attempt in $(seq 1 20); do
    EIGS_REPLAY="$T/sleep.tape" "$EIGS" "$T/sleep.eigs" > "$T/sleep.replay" || sleep_ok=0
    cmp -s "$T/sleep.record" "$T/sleep.replay" || sleep_ok=0
done
if [ "$sleep_ok" -eq 1 ]; then
    ok "sleep_orders_spawned_output matches across 20 replays"
else bad "replay sleep ordering" "record=$(cat "$T/sleep.record") replay=$(cat "$T/sleep.replay")"; fi

# 6: EOF joins the worker before the REPL samples graceful_exit_code.
set +e
printf 'define later() as:\n    usleep of 100000\n    set_exit_code of 23\nh is spawn of later\n' | "$EIGS" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 23 ] && ok "REPL EOF reaps workers before reading exit code" || bad "REPL worker exit" "rc=$rc"

echo "ISSUE 1914 FOLLOW-UP: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
