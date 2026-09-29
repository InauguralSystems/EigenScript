#!/bin/bash
# #1147: the cycle collector resumes MID-RUN once every spawned worker is
# joined. `multithreaded` used to be cleared only by the exit drain, so one
# spawn+join turned collection off for the rest of the run: a closure-cycle
# loop after it peaked at ~12x the RSS of the same loop with no spawn (100k
# iterations; 117x at 300k).
#
# Peak RSS is read with getrusage(RUSAGE_CHILDREN) from a fresh python per
# program, so each figure is that one child's high-water mark. Each is taken
# as GROWTH over `base` (the same prologue, no loop): a sanitizer build's
# fixed startup footprint (~85 MB under ASan) would otherwise compress every
# ratio toward 1. Only ratios of growths are compared, so the unit (kB on
# Linux, bytes on macOS) cancels.
#
#   base      prologue only                              -> startup footprint
#   control   the loop, no spawn                         -> reference growth
#   joined    spawn + join, then the loop                -> must stay near it
#   unjoined  a worker is parked on recv during the loop -> must NOT (the
#             collector is correctly off while a worker lives; this is the
#             witness that the measurement can see the leak at all)
#   respawn   join, collect, spawn again, nested spawn   -> exact results
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="${EIGS:-$TESTS_DIR/../src/eigenscript}"
# The joined run's growth must stay within BOUND x the control's. Measured
# (release): ~1x fixed, ~18x before the fix. The unjoined witness's growth
# must exceed WITNESS x the control's.
BOUND=3
WITNESS=4
N=${SPAWN_GC_N:-100000}
# ASan's quarantine keeps freed blocks out of reuse (256 MB by default), so on
# a sanitized build even a program whose cycles ARE collected grows by what it
# freed: the control grew 55 MB and the live-worker witness only 3.7x that.
# Disable it for these children (the caller's other options, detect_leaks
# included, are kept); a no-op on an unsanitized build.
export ASAN_OPTIONS="${ASAN_OPTIONS:+$ASAN_OPTIONS:}quarantine_size_mb=0"
PASS=0; FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 not found (peak RSS unmeasurable)"
    echo "SPAWN_GC_RESUME: $PASS passed, $FAIL failed"; exit 1
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs_spawn_gc.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

prologue() {
    cat <<'EOF'
define make_counter(start) as:
    count is start
    define value() as:
        return count
    return value
define noop(n) as:
    return n
define parked(ch) as:
    return recv of ch
EOF
}
loop() {
    cat <<EOF
i is 0
loop while i < $N:
    local c is make_counter of i
    i is i + 1
EOF
}
{ prologue; echo 'h is noop of 1'; echo 'print of "done"'; } > "$TMP/base.eigs"
{ prologue; echo 'h is noop of 1'; loop; echo 'print of "done"'; } > "$TMP/control.eigs"
{ prologue; printf 'h is spawn of [noop, 1]\nthread_join of h\n'; loop; echo 'print of "done"'; } > "$TMP/joined.eigs"
{ prologue; printf 'ch is channel of null\nh is spawn of [parked, ch]\n'; loop
  printf 'send of [ch, 1]\nthread_join of h\nprint of "done"\n'; } > "$TMP/unjoined.eigs"

peak() {   # peak <program> -> "<maxrss> <rc>"
    python3 - "$EIGS" "$1" <<'EOF'
import resource, subprocess, sys
p = subprocess.run(sys.argv[1:], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
ok = p.returncode == 0 and p.stdout.strip().endswith(b'done')
print(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss, 0 if ok else 1)
EOF
}

read -r B_KB B_RC <<<"$(peak "$TMP/base.eigs")"
read -r C_KB C_RC <<<"$(peak "$TMP/control.eigs")"
read -r J_KB J_RC <<<"$(peak "$TMP/joined.eigs")"
read -r U_KB U_RC <<<"$(peak "$TMP/unjoined.eigs")"
echo "  peak RSS (N=$N): base=$B_KB control=$C_KB joined=$J_KB unjoined=$U_KB"
if [ "$B_RC$C_RC$J_RC$U_RC" != "0000" ] || [ "${B_KB:-0}" -le 0 ]; then
    fail "a program failed to run to 'done' (rc base=$B_RC control=$C_RC joined=$J_RC unjoined=$U_RC)"
else
    # Growth over the startup footprint. A collected loop grows ~nothing on
    # a release build (its freed cycles are reused: 0 measured), so the
    # control's growth is floored at a quarter of the startup footprint —
    # scale-free, unit-free, and far below the ~110 MB a live worker (or the
    # pre-fix join) costs at N=100k.
    GC=$((C_KB - B_KB)); FLOOR=$((B_KB / 4)); [ "$GC" -ge "$FLOOR" ] || GC=$FLOOR
    GJ=$((J_KB - B_KB)); GU=$((U_KB - B_KB))
    echo "  growth over base: control=$GC joined=$GJ unjoined=$GU"
    if [ "$GJ" -le $((GC * BOUND)) ]; then
        pass "spawn+join then cycle loop grows within ${BOUND}x the no-spawn control ($GJ <= $GC x $BOUND)"
    else
        fail "spawn+join then cycle loop grows $GJ, over ${BOUND}x the control's $GC — the collector did not resume after the join"
    fi
    if [ "$GU" -gt $((GC * WITNESS)) ]; then
        pass "witness: with a worker live during the loop growth exceeds ${WITNESS}x ($GU > $GC x $WITNESS) — the measurement sees the leak"
    else
        fail "witness: a live worker during the loop grew only $GU (want > $GC x $WITNESS) — the RSS measurement cannot see the regression it gates"
    fi
fi

# Respawn after the clear: the flag goes 1 -> 0 -> 1, and a worker that
# spawns its own worker keeps the state MT until BOTH are joined.
cat > "$TMP/respawn.eigs" <<'EOF'
define sq(n) as:
    return n * n
define spawner(n) as:
    inner is spawn of [sq, n]
    return thread_join of inner
define make_counter(start) as:
    count is start
    define value() as:
        return count
    return value
total is 0
round is 0
loop while round < 3:
    hs is []
    for k in range of 4:
        append of [hs, spawn of [sq, k + round]]
    for h in hs:
        total is total + (thread_join of h)
    j is 0
    loop while j < 20000:
        local c is make_counter of j
        j is j + 1
    round is round + 1
nested is spawn of [spawner, 7]
print of (thread_join of nested)
print of total
EOF
R_OUT=$("$EIGS" "$TMP/respawn.eigs" 2>&1); R_RC=$?
# total = sum over round in 0..2 of sum over k in 0..3 of (k+round)^2 = 14+30+54
if [ "$R_RC" -eq 0 ] && [ "$R_OUT" = "$(printf '49\n98')" ]; then
    pass "join, collect, spawn again (3 rounds) and a nested spawn give exact results"
else
    fail "respawn after join: rc=$R_RC output=$(printf '%s' "$R_OUT" | tr '\n' ' ' | head -c 300)"
fi

echo "SPAWN_GC_RESUME: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
