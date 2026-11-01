#!/bin/bash
# hq#58: the peak-RSS half of [70d] (tests/test_temporal_memory.sh, #827) may
# skip only for a key listed WITH a reason in
# tests/temporal_memory_skip_allowlist.txt. Any other skip is a FAIL.
#
# Before hq#58 the child printed SKIP and exited 0 whenever GNU time was
# missing, which was every container lane (the dev image had no `time`), and
# the runner counted nothing: `RESULTS: 3/3 passed, 0 failed, 0 skipped` for
# a section that measured no RSS at all. Each case below hides GNU time by
# pointing the child at a path that does not exist (TMEM_GNU_TIME), which is
# that exact environment, and checks what the REAL child then reports.
#
# The key the child must report depends on the host: no /proc (macOS) and
# sanitizer builds decline before GNU time is probed. Everywhere else it is
# no-gnu-time, which the shipped allowlist deliberately does not list.
# The #868 window checks need none of those, so every case also requires
# that all four of them ran and passed.
#
# Run from src/ like the child (EIGS defaults to ./eigenscript). Prints
# `temporal-memory skips: N passed, M failed`; exit 0 only when M is 0.
set -u
TESTS="$(cd "$(dirname "$0")" && pwd)"
EIGS="${EIGS:-./eigenscript}"
CHILD="$TESTS/test_temporal_memory.sh"
LIST="$TESTS/temporal_memory_skip_allowlist.txt"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs_tmem_skips.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
NOTIME="$WORK/no-such-gnu-time"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); printf '%s\n' "${2:-}" | tail -8 | sed 's/^/      /'; }

if [ ! -r /proc/self/status ]; then KEY=no-procfs
elif grep -qa "__asan_init" "$EIGS" 2>/dev/null; then KEY=sanitizer
else KEY=no-gnu-time
fi

run_child() {   # <allowlist path>: sets OUT and RC
    OUT=$(TMEM_GNU_TIME="$NOTIME" TMEM_SKIP_ALLOWLIST="$1" EIGS="$EIGS" command bash "$CHILD" 2>&1)
    RC=$?
}
skip_lines() { printf '%s\n' "$OUT" | grep -c '^  SKIP:'; }

# 1. The shipped allowlist: every entry carries a reason, and no-gnu-time is
#    absent. Re-adding it would bring back the skip that hid this gate.
BAD_ROWS=$(awk -F '\t' '/^#/ || /^[[:space:]]*$/ { next }
    NF < 2 || $2 !~ /[^[:space:]]/ { print NR ": " $0 }' "$LIST")
ROWS=$(grep -vcE '^(#|[[:space:]]*$)' "$LIST")
if [ ! -s "$LIST" ] || [ "$ROWS" -lt 1 ] || [ -n "$BAD_ROWS" ]; then
    bad "allowlist has an entry without a reason, or no entries ($ROWS rows)" "$BAD_ROWS"
elif awk -F '\t' '$1 == "no-gnu-time"' "$LIST" | grep -q .; then
    bad "allowlist lists no-gnu-time: a Linux box without GNU time would skip the gate again"
else
    ok "shipped allowlist: $ROWS entries, each with a reason; no-gnu-time not listed"
fi

# 2. The shipped allowlist with GNU time gone: a FAIL on Linux, a counted
#    allowlisted SKIP on macOS and sanitizer builds.
run_child "$LIST"
if [ "$KEY" = no-gnu-time ]; then
    if [ "$RC" -ne 0 ] && grep -qx 'TEMPORAL_MEM: 4 passed, 1 failed, 0 skipped' <<< "$OUT" \
       && grep -q "^  FAIL: peak-RSS half not measured: .*skip 'no-gnu-time' is not in" <<< "$OUT" \
       && [ "$(skip_lines)" -eq 0 ]; then
        ok "GNU time missing on Linux FAILS the gate (rc=$RC) and the 4 window checks still pass"
    else
        bad "GNU time missing on Linux did not fail the gate (rc=$RC)" "$OUT"
    fi
else
    if [ "$RC" -eq 0 ] && grep -qx 'TEMPORAL_MEM: 4 passed, 0 failed, 1 skipped' <<< "$OUT" \
       && [ "$(skip_lines)" -eq 1 ] && grep -q "\[allowlisted: $KEY\]$" <<< "$OUT"; then
        ok "$KEY host: one counted allowlisted skip, and the 4 window checks still pass"
    else
        bad "$KEY host: expected one counted allowlisted skip (rc=$RC)" "$OUT"
    fi
fi

# 3. A scratch allowlist that lists this host's key WITH a reason: the skip is
#    allowed, printed once, and reported in the summary's skipped count.
printf '%s\treason written by a reviewer\n' "$KEY" > "$WORK/allow.reason"
run_child "$WORK/allow.reason"
if [ "$RC" -eq 0 ] && grep -qx 'TEMPORAL_MEM: 4 passed, 0 failed, 1 skipped' <<< "$OUT" \
   && [ "$(skip_lines)" -eq 1 ] && grep -q "\[allowlisted: $KEY\]$" <<< "$OUT"; then
    ok "a listed key with a reason is one counted skip ($KEY)"
else
    bad "a listed key with a reason was not one counted skip ($KEY, rc=$RC)" "$OUT"
fi

# 4. The same key with an empty reason, or with no reason field: not a waiver.
printf '%s\t\n%s\n' "$KEY" "$KEY" > "$WORK/allow.noreason"
run_child "$WORK/allow.noreason"
if [ "$RC" -ne 0 ] && grep -qx 'TEMPORAL_MEM: 4 passed, 1 failed, 0 skipped' <<< "$OUT" \
   && [ "$(skip_lines)" -eq 0 ]; then
    ok "a listed key without a reason still FAILS ($KEY, rc=$RC)"
else
    bad "a listed key without a reason was accepted ($KEY, rc=$RC)" "$OUT"
fi

# 5. No allowlist file at all fails closed.
run_child "$WORK/absent-allowlist.txt"
if [ "$RC" -ne 0 ] && grep -qx 'TEMPORAL_MEM: 4 passed, 1 failed, 0 skipped' <<< "$OUT"; then
    ok "a missing allowlist fails closed (rc=$RC)"
else
    bad "a missing allowlist did not fail closed (rc=$RC)" "$OUT"
fi

echo "temporal-memory skips: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
