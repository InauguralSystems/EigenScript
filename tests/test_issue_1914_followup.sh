#!/usr/bin/env bash
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
for shape in '[]' '[1]' '["a", "b"]'; do
    printf '%s\nB 0 1 1 0 root -\nN 0 md5_file=%s\n' "$vh" "$shape" > "$T/md5.tape"
    out=$(EIGS_REPLAY="$T/md5.tape" "$EIGS" "$T/md5.eigs" 2>&1)
    echo "$out" | grep -q 'md5_file: recorded result has invalid replay shape' || shape_ok=0
done
[ "$shape_ok" -eq 1 ] && ok "malformed md5_file error lists are refused" || bad "md5_file shapes" "one was accepted"

# 4: changing the host clock cannot change a replayed SDL tick value.
printf 'print of (gfx_ticks of null)\n' > "$T/ticks.eigs"
EIGS_TRACE="$T/ticks.tape" "$EIGS" "$T/ticks.eigs" > "$T/ticks.record"
sleep 1
EIGS_REPLAY="$T/ticks.tape" "$EIGS" "$T/ticks.eigs" > "$T/ticks.replay"
if cmp -s "$T/ticks.record" "$T/ticks.replay" && grep -q ' gfx_ticks=' "$T/ticks.tape"; then
    ok "gfx_ticks is tape-served"
else bad "gfx_ticks tape" "record=$(cat "$T/ticks.record") replay=$(cat "$T/ticks.replay")"; fi

# 5: replay validates the argument but skips the program-requested wait.
printf 'usleep of 1500000\nprint of "awake"\n' > "$T/sleep.eigs"
EIGS_TRACE="$T/sleep.tape" "$EIGS" "$T/sleep.eigs" >/dev/null
start=$(python3 -c 'import time; print(time.monotonic())')
out=$(EIGS_REPLAY="$T/sleep.tape" "$EIGS" "$T/sleep.eigs")
elapsed=$(python3 - "$start" <<'PY'
import sys,time
print(time.monotonic()-float(sys.argv[1]))
PY
)
if [ "$out" = awake ] && python3 - "$elapsed" -c 'import sys; raise SystemExit(not float(sys.argv[1]) < 1.0)'; then
    ok "replay skips usleep"
else bad "replay sleep" "elapsed=$elapsed out=$out"; fi

# 6: EOF joins the worker before the REPL samples graceful_exit_code.
set +e
printf 'define later() as:\n    usleep of 100000\n    set_exit_code of 23\nh is spawn of later\n' | "$EIGS" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 23 ] && ok "REPL EOF reaps workers before reading exit code" || bad "REPL worker exit" "rc=$rc"

echo "ISSUE 1914 FOLLOW-UP: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
