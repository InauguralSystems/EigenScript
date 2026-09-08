#!/usr/bin/env bash
# #1112: a replay-boundary refusal (`recv` & co. under EIGS_REPLAY, docs/TRACE.md
# "Non-Replayable Builtins") raised on a spawn()ed worker that runs the builtin
# DIRECTLY (`spawn of [recv, ch]`) died by SIGSEGV: rt_error printed the
# uncaught error immediately (no VM to defer to on that thread) and
# vm_print_stack_trace dereferenced the worker's NULL VM. The same shape killed
# any uncaught raise on such a worker with no replay at all
# (`spawn of [recv, 5]`), and an uncaught death on a VAL_FN worker exited 0.
# Contract pinned here: a boundary refusal is a clean exit -- rc 1, never a
# signal -- and a worker that dies of an uncaught error fails the process (the
# #493 rule for tasks, applied to threads). Runs with cwd src/ like every child
# script; prints PASS:/FAIL: lines; exit 1 on any FAIL.
#
# Bounding is pure shell (macOS runners have no `timeout`): background, poll,
# kill at the deadline. stdin is /dev/null so the proc_* record arms never touch
# a live terminal fd.
EIGS="${EIGS:-./eigenscript}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()   { echo "PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
[ -x "$EIGS" ] || { bad "eigenscript binary not found at $EIGS"; echo "REPLAY_BOUNDARY_EXIT: $PASS passed, $FAIL failed"; exit 1; }

# run_bounded OUTFILE [ENV=val ...] -- PROG ; sets RC ("" = killed at the deadline)
run_bounded() {
    local out="$1"; shift
    env -u EIGS_JIT_OSR_THRESHOLD "$@" > "$out" 2>&1 </dev/null &
    local pid=$!
    RC=""
    for _ in $(seq 1 100); do
        if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; RC=$?; break; fi
        sleep 0.1
    done
    if [ -z "$RC" ]; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; echo "  (killed after 10s)" >> "$out"; fi
}
# A sanitizer diagnostic in either arm is a hard failure here (the
# check_task_exit convention -- stricter than rc_ok's leak tolerance).
clean() { ! grep -qE "Sanitizer|runtime error:" "$1"; }
DIAG="not replayable under EIGS_REPLAY"

# assert_replay NAME PROG EXTRA_ENV... -- record (JIT off), then replay; the
# replay arm must exit exactly 1, print the boundary diagnostic, and not die
# by signal (rc >= 128) in either arm.
assert_replay() {
    local name="$1" prog="$2"; shift 2
    rm -f "$T/tape"
    run_bounded "$T/rec" EIGS_JIT_OFF=1 EIGS_TRACE="$T/tape" "$@" "$EIGS" "$prog"; local rrc="$RC"
    if [ -z "$rrc" ] || [ "$rrc" -ne 0 ] || [ ! -s "$T/tape" ] || ! clean "$T/rec"; then
        bad "$name: record arm rc=${rrc:-hung} tape=$( [ -s "$T/tape" ] && echo written || echo MISSING)"; head -3 "$T/rec" | sed 's/^/    /'; return
    fi
    run_bounded "$T/rep" EIGS_JIT_OFF=1 EIGS_REPLAY="$T/tape" "$@" "$EIGS" "$prog"; local prc="$RC"
    if [ "$prc" = "1" ] && grep -q "$DIAG" "$T/rep" && clean "$T/rep"; then
        ok "$name: replay refusal is a clean exit (rc=1, diagnostic printed, no signal)"
    else
        bad "$name: replay rc=${prc:-hung} (want 1, no signal) diag=$(grep -c "$DIAG" "$T/rep")"; head -4 "$T/rep" | sed 's/^/    /'
    fi
}

# 1. The issue's exact reproducer: tests/test_spawn_channel_exit.eigs
#    (a worker parked in `recv` on a never-closed channel). Both tiers: the
#    replay arm is also run with the JIT on (#279 class -- tiers drift alone).
assert_replay "issue #1112 repro (test_spawn_channel_exit)" ../tests/test_spawn_channel_exit.eigs
run_bounded "$T/rep_jit" EIGS_REPLAY="$T/tape" "$EIGS" ../tests/test_spawn_channel_exit.eigs
if [ "$RC" = "1" ] && grep -q "$DIAG" "$T/rep_jit" && clean "$T/rep_jit"; then ok "issue #1112 repro, JIT on: rc=1, clean"; else bad "issue #1112 repro, JIT on: rc=${RC:-hung}"; head -3 "$T/rep_jit" | sed 's/^/    /'; fi

# 2. Every boundary builtin (docs/TRACE.md #148 list) as a DIRECT worker --
#    the issue names one instance of the class; all 11 crashed the same
#    way before the fix (the 11 replay_blocks() call sites in builtins.c and
#    builtins_host.c). Channel family + subprocess family.
printf 'ch is channel of 1\nw is spawn of [recv, ch]\nprint of "MARK_END"\n'            > "$T/b_recv.eigs"
printf 'ch is channel of 1\nw is spawn of [try_recv, ch]\nprint of "MARK_END"\n'        > "$T/b_try_recv.eigs"
printf 'ch is channel of 1\nw is spawn of [recv_timeout, ch, 5]\nprint of "MARK_END"\n' > "$T/b_recv_timeout.eigs"
printf 'w is spawn of [exec_capture, ["true"]]\nprint of "MARK_END"\n'                   > "$T/b_exec_capture.eigs"
printf 'w is spawn of [proc_spawn, ["true"]]\nprint of "MARK_END"\n'                     > "$T/b_proc_spawn.eigs"
printf 'w is spawn of [proc_write, 0, "x"]\nprint of "MARK_END"\n'                       > "$T/b_proc_write.eigs"
printf 'w is spawn of [proc_read_line, 0]\nprint of "MARK_END"\n'                        > "$T/b_proc_read_line.eigs"
printf 'w is spawn of [proc_read, 0, 1]\nprint of "MARK_END"\n'                          > "$T/b_proc_read.eigs"
printf 'w is spawn of [proc_read_buf, 0, 1]\nprint of "MARK_END"\n'                      > "$T/b_proc_read_buf.eigs"
printf 'w is spawn of [proc_close, 0]\nprint of "MARK_END"\n'                            > "$T/b_proc_close.eigs"
printf 'w is spawn of [proc_wait, 0]\nprint of "MARK_END"\n'                             > "$T/b_proc_wait.eigs"
for b in recv try_recv recv_timeout exec_capture proc_spawn proc_write proc_read_line proc_read proc_read_buf proc_close proc_wait; do
    assert_replay "boundary builtin $b on a direct worker" "$T/b_$b.eigs"
done

# 3. Control, no replay at all: an ordinary raise on a direct worker was the
#    same NULL-VM crash (`recv of 5` -> "invalid channel" -> SIGSEGV).
printf 'w is spawn of [recv, 5]\nprint of "MARK_END"\n' > "$T/c_raise.eigs"
run_bounded "$T/c1" "$EIGS" "$T/c_raise.eigs"
if [ "$RC" = "1" ] && grep -q "invalid channel" "$T/c1" && grep -q MARK_END "$T/c1" && clean "$T/c1"; then ok "uncaught raise on a direct worker, no replay: rc=1, no signal"; else bad "uncaught raise on a direct worker: rc=${RC:-hung}"; head -3 "$T/c1" | sed 's/^/    /'; fi

# 4. A VAL_FN worker that dies of an uncaught error fails the process (was rc 0
#    -- the silent-success #493 closed for tasks). Unjoined and joined.
printf 'define w() as:\n    return recv of 5\nh is spawn of w\nprint of "MARK_END"\n' > "$T/c_fn.eigs"
run_bounded "$T/c2" "$EIGS" "$T/c_fn.eigs"
if [ "$RC" = "1" ] && grep -q MARK_END "$T/c2" && clean "$T/c2"; then ok "VAL_FN worker uncaught death (unjoined): rc=1"; else bad "VAL_FN worker uncaught death (unjoined): rc=${RC:-hung}"; fi
printf 'define w() as:\n    return recv of 5\nh is spawn of w\nr is thread_join of h\nprint of "MARK_END"\n' > "$T/c_fnj.eigs"
run_bounded "$T/c3" "$EIGS" "$T/c_fnj.eigs"
if [ "$RC" = "1" ] && grep -q MARK_END "$T/c3" && clean "$T/c3"; then ok "VAL_FN worker uncaught death (joined): rc=1"; else bad "VAL_FN worker uncaught death (joined): rc=${RC:-hung}"; fi

# 5. Positive controls (the other half): a CAUGHT error in the worker, a
#    worker's `exit of N`, and a clean worker all keep their exit status.
printf 'define w() as:\n    try:\n        r is recv of 5\n    catch e:\n        print of "caught"\n    return 7\nh is spawn of w\nprint of (thread_join of h)\n' > "$T/c_caught.eigs"
run_bounded "$T/c4" "$EIGS" "$T/c_caught.eigs"
if [ "$RC" = "0" ] && grep -q "^caught" "$T/c4" && grep -q "^7" "$T/c4"; then ok "error caught inside the worker: rc=0"; else bad "error caught inside the worker: rc=${RC:-hung}"; fi
printf 'define w() as:\n    exit of 4\nh is spawn of w\nr is thread_join of h\nprint of "MARK_END"\n' > "$T/c_exit4.eigs"
run_bounded "$T/c5" "$EIGS" "$T/c_exit4.eigs"
if [ "$RC" = "4" ]; then ok "worker exit of 4 still decides the status: rc=4"; else bad "worker exit of 4: rc=${RC:-hung} (want 4)"; fi
printf 'define w() as:\n    exit of 0\nh is spawn of w\nr is thread_join of h\nprint of "MARK_END"\n' > "$T/c_exit0.eigs"
run_bounded "$T/c6" "$EIGS" "$T/c_exit0.eigs"
if [ "$RC" = "0" ]; then ok "worker exit of 0 is a request, not a death: rc=0"; else bad "worker exit of 0: rc=${RC:-hung} (want 0)"; fi
printf 'define w() as:\n    return 3\nh is spawn of w\nprint of (thread_join of h)\n' > "$T/c_clean.eigs"
run_bounded "$T/c7" "$EIGS" "$T/c_clean.eigs"
if [ "$RC" = "0" ] && grep -q "^3" "$T/c7"; then ok "clean worker: rc=0"; else bad "clean worker: rc=${RC:-hung}"; fi

# 6. Main-thread boundary refusal (a VM is live there; already clean before
#    the fix) stays rc 1 -- the guard must not have changed the deferred path.
printf 'ch is channel of 1\nr is try_recv of ch\nprint of "MARK_END"\n' > "$T/m.eigs"
assert_replay "main-thread try_recv refusal (control)" "$T/m.eigs"

echo "REPLAY_BOUNDARY_EXIT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
