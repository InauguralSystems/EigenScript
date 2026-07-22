#!/usr/bin/env bash
# [99e] SIGUSR1 live observer dump (#660) — drive the signal against a LIVE
# process from outside, assert the dump's shape (incl. `when=` assign
# counts), and require the program to continue and exit normally.
#
# Synchronization is on OBSERVABLE STATE only (the #604 proc_stream rule: a
# spin loop only hopes the child was scheduled in time): the child prints a
# READY marker to stdout (builtin_print fflushes) once inside its long loop;
# we poll for that line, then `kill -USR1`. The dump's own "# end dump"
# trailer on stderr acknowledges the safepoint fired. Then we wait for the
# child to finish ON ITS OWN (bounded — a hung child is a FAIL, never a hung
# suite) and require the DONE marker + exit 0.
#
# Subtest 1 (single thread): the entire wait runs INSIDE one train() call,
# so the dump deterministically catches a live frame: module-scope
# step_count must show a large `when` (settled, long-lived) while the
# per-call parameter n shows when=1 (fresh) — the when=1-vs-settled
# distinction the issue calls this feature's silent-tolerance failure when
# the assign count is missing.
#
# Subtest 2 (spawned task): same module-row assertions while a worker churns
# module-env reads concurrently (exercises the #607 module-env lock the dump
# holds under MT). Whichever thread observes the flag performs the dump, so
# only module-scope rows are asserted here. Under LeakSanitizer the known
# spawn-thread leak shapes are tolerated exactly like the main runner's
# rc_ok (pass + note); AddressSanitizer/UBSan errors never are.

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$TESTS_DIR/../src/eigenscript"

FIX1=/tmp/eigs_sigusr1_a_$$.eigs
FIX2=/tmp/eigs_sigusr1_b_$$.eigs
OUT1=/tmp/eigs_sigusr1_a_$$.out
ERR1=/tmp/eigs_sigusr1_a_$$.err
OUT2=/tmp/eigs_sigusr1_b_$$.out
ERR2=/tmp/eigs_sigusr1_b_$$.err
PIDS=""

cleanup() {
    for p in $PIDS; do
        kill "$p" 2>/dev/null || true
        wait "$p" 2>/dev/null || true
    done
    rm -f "$FIX1" "$FIX2" "$OUT1" "$ERR1" "$OUT2" "$ERR2"
}
trap cleanup EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; }

# poll_file <file> <pattern> <tenths> — wait up to <tenths>/10 seconds for
# grep -qE <pattern> <file> to succeed (observable-state barrier).
poll_file() {
    local f=$1 pat=$2 tenths=$3 i
    for i in $(seq 1 "$tenths"); do
        grep -qE "$pat" "$f" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}

cat > "$FIX1" <<'EOF'
step_count is 0
epsilon is 1.0
define train(n) as:
    loss is 5.0
    scale is 0.999
    loop while step_count < n:
        step_count is step_count + 1
        loss is loss * scale + 0.001
        epsilon is epsilon * 0.99999
        if step_count == 5000:
            print of "READY"
    return loss
r is train of 2000000
print of "DONE"
EOF

# ---- Subtest 1: single-thread dump shape -------------------------------

"$EIGS" "$FIX1" > "$OUT1" 2> "$ERR1" &
PID=$!
PIDS="$PIDS $PID"

if poll_file "$OUT1" "^READY$" 600; then
    pass "sigusr1: child reached its loop (READY barrier)"
else
    fail "sigusr1: child never printed READY (dead or hung before the loop)"
fi

if ! kill -USR1 "$PID" 2>/dev/null; then
    fail "sigusr1: child exited before the signal (no live process to dump)"
fi

if poll_file "$ERR1" "^# end dump$" 600; then
    pass "sigusr1: dump arrived at a loop safepoint"
else
    fail "sigusr1: no dump on stderr after SIGUSR1"
fi

# Row shape: name | value | when=<assigns> | entropy=<H> | dH=<dH> | word.
# when must have 4+ digits (READY is printed at assignment 5000 of
# step_count, the signal lands strictly after) — a settled long-lived
# binding, visibly distinct from a fresh per-call one.
if grep -qE '^step_count \| [0-9]+ \| when=[0-9]{4,} \| entropy=[^ ]+ \| dH=[^ ]+ \| [a-z]+$' "$ERR1"; then
    pass "sigusr1: module row shape (name|value|when|entropy|dH|trajectory) with settled when"
else
    fail "sigusr1: module step_count row missing/misshaped"
fi

# The when=1 counterproof: the live frame's parameter n was bound once this
# call — it must NOT read as settled.
if grep -qE '^# scope=frame$' "$ERR1" \
   && grep -qE '^n \| 2000000 \| when=1 \| entropy=- \| dH=- \| unobserved$' "$ERR1"; then
    pass "sigusr1: live-frame row with fresh when=1 binding (distinguishable from settled)"
else
    fail "sigusr1: live-frame when=1 row for parameter n missing"
fi

if grep -qE '^loss \| [0-9.]+ \| when=[0-9]{4,} \| entropy=[^ ]+ \| dH=[^ ]+ \| [a-z]+$' "$ERR1"; then
    pass "sigusr1: fn-local row carries its accumulated when count"
else
    fail "sigusr1: fn-local loss row missing/misshaped"
fi

# The program must continue correctly after the dump: DONE marker, then a
# clean exit on its own. DONE is the observable barrier; the wait below only
# reaps (teardown after DONE cannot hang).
if poll_file "$OUT1" "^DONE$" 1200; then
    pass "sigusr1: program completed (DONE) after the dump"
else
    fail "sigusr1: program never completed after the dump"
fi
wait "$PID"; RC1=$?
PIDS="${PIDS% $PID}"
if [ "$RC1" = "0" ]; then
    pass "sigusr1: exit code 0 after the dump"
else
    fail "sigusr1: exit code $RC1 after the dump (expected 0)"
fi

# Sanitizer hygiene on the dump path itself (release build: all absent).
if grep -qE 'AddressSanitizer|LeakSanitizer|runtime error:' "$ERR1"; then
    fail "sigusr1: sanitizer report on stderr (single-thread run)"
else
    pass "sigusr1: no sanitizer report (single-thread run)"
fi

# ---- Subtest 2: dump with a spawned task live --------------------------

cat > "$FIX2" <<'EOF'
step_count is 0
define churn(n) as:
    i is 0
    probe is 0
    loop while i < n:
        i is i + 1
        probe is step_count
    return probe
t is spawn of [churn, 2500000]
define train(n) as:
    loss is 5.0
    loop while step_count < n:
        step_count is step_count + 1
        loss is loss * 0.999 + 0.001
        if step_count == 5000:
            print of "READY"
    return loss
r is train of 2000000
thread_join of t
print of "DONE"
EOF

"$EIGS" "$FIX2" > "$OUT2" 2> "$ERR2" &
PID=$!
PIDS="$PIDS $PID"

if poll_file "$OUT2" "^READY$" 600; then
    pass "sigusr1-mt: child reached its loop with a task live"
else
    fail "sigusr1-mt: child never printed READY"
fi

if ! kill -USR1 "$PID" 2>/dev/null; then
    fail "sigusr1-mt: child exited before the signal"
fi

# Whichever thread observes the flag dumps; the module scope is in both
# views, so the settled module row is deterministic.
if poll_file "$ERR2" "^# end dump$" 600; then
    pass "sigusr1-mt: dump arrived under a live task"
else
    fail "sigusr1-mt: no dump on stderr after SIGUSR1"
fi

if grep -qE '^step_count \| [0-9]+ \| when=[0-9]{4,} \| entropy=[^ ]+ \| dH=[^ ]+ \| [a-z]+$' "$ERR2"; then
    pass "sigusr1-mt: module row shape with settled when"
else
    fail "sigusr1-mt: module step_count row missing/misshaped"
fi

if poll_file "$OUT2" "^DONE$" 1200; then
    pass "sigusr1-mt: program completed (DONE) after the dump"
else
    fail "sigusr1-mt: program never completed after the dump"
fi
wait "$PID"; RC2=$?
PIDS="${PIDS% $PID}"

# Mirror the main runner's rc_ok: a LeakSanitizer nonzero exit from the
# known spawn-thread leak shapes counts as a pass-with-note; any hard
# ASan/UBSan report is a failure in both subtests.
if grep -qE 'AddressSanitizer|runtime error:' "$ERR2"; then
    fail "sigusr1-mt: ASan/UBSan report on stderr"
elif [ "$RC2" = "0" ]; then
    pass "sigusr1-mt: clean exit after the dump"
elif grep -q 'LeakSanitizer: detected memory leaks' "$ERR2"; then
    pass "sigusr1-mt: LeakSanitizer nonzero exit (known spawn-thread leak shape; tolerated like rc_ok)"
else
    fail "sigusr1-mt: exit code $RC2 after the dump (expected 0)"
fi
