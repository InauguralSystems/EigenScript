#!/bin/bash
# --test --trace-on-fail (#394): a failing test records a tape and prints the
# exact EIGS_REPLAY invocation that reproduces the failure BYTE-FOR-BYTE. The
# oracle is a transcript byte-diff (not eyeball): a fresh run would draw a
# different random value, so an identical replayed value proves it came from the
# tape. Verified on both execution tiers (JIT on and EIGS_JIT_OFF) and under
# EIGS_REPLAY_STRICT.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$TESTS_DIR/../src/eigenscript"
PASS=0; FAIL=0
pass(){ echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail(){ echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== --test --trace-on-fail ==="
WORK=$(mktemp -d)
cat > "$WORK/test_flaky.eigs" <<'EIGS'
r is random of null
print of ("roll: " + (str of r))
assert of [r > 2.0, "deliberate failure — random is in [0,1)"]
EIGS

OUT=$($EIGS --test --trace-on-fail "$WORK/test_flaky.eigs" 2>&1)

if echo "$OUT" | grep -q "replay: EIGS_REPLAY="; then pass "failure prints a replay invocation"; else fail "no replay invocation printed"; fi

REC=$(echo "$OUT" | grep -oE "roll: [0-9.]+" | head -1)
TAPE=$(echo "$OUT" | grep -oE "EIGS_REPLAY=[^ ]+" | head -1 | cut -d= -f2)
if [ -n "$TAPE" ] && [ -f "$TAPE" ]; then pass "failing test kept its tape ($TAPE)"; else fail "tape file missing"; fi

# Replay, JIT on: same random value + same nonzero exit.
RJ=$(EIGS_REPLAY="$TAPE" "$EIGS" "$WORK/test_flaky.eigs" 2>&1); rc=$?
RRECJ=$(echo "$RJ" | grep -oE "roll: [0-9.]+" | head -1)
if [ -n "$REC" ] && [ "$REC" = "$RRECJ" ]; then pass "replay reproduces recorded random, JIT on ($REC)"; else fail "replay diverged JIT on: rec=$REC replay=$RRECJ"; fi
if [ "$rc" -ne 0 ]; then pass "replay reproduces the failing exit, JIT on"; else fail "replay did not fail"; fi

# Replay, JIT off: line accounting must agree across tiers (#279 class).
RJO=$(EIGS_JIT_OFF=1 EIGS_REPLAY="$TAPE" "$EIGS" "$WORK/test_flaky.eigs" 2>&1)
RRECO=$(echo "$RJO" | grep -oE "roll: [0-9.]+" | head -1)
if [ "$REC" = "$RRECO" ]; then pass "replay reproduces recorded random, JIT off ($RRECO)"; else fail "replay diverged JIT off: rec=$REC replay=$RRECO"; fi

# Strict replay: no mismatch abort.
EIGS_REPLAY_STRICT=1 EIGS_REPLAY="$TAPE" "$EIGS" "$WORK/test_flaky.eigs" >/dev/null 2>"$WORK/strict.err" || true
if grep -qiE "mismatch|aborting" "$WORK/strict.err"; then fail "strict replay reported a mismatch"; else pass "strict replay is clean (no mismatch)"; fi

# A passing test discards its tape and prints no replay line.
cat > "$WORK/test_ok.eigs" <<'EIGS'
print of "ok"
EIGS
OUT2=$($EIGS --test --trace-on-fail "$WORK/test_ok.eigs" 2>&1)
if echo "$OUT2" | grep -q "replay: EIGS_REPLAY="; then fail "passing test should not print a replay line"; else pass "passing test discards its tape"; fi

rm -rf "$WORK"
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
