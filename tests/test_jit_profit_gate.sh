#!/usr/bin/env bash
# [99zb] The JIT thunk-profitability gate (#1178).
#
# The gate decides, per chunk, whether entering a compiled thunk is worth its
# entry/exit cost. It has FOUR conditional arms, and each one below has a
# fixture whose verdict CHANGES when that arm is switched off -- the arm's
# env knob is the "disable" (mechanical-gates section 116). Three of the four
# were bought by a real regression during the round that added them:
#
#   A. the gate itself          EIGS_JIT_PROFIT_MIN=0
#   B. the RETURN exemption     EIGS_JIT_PROFIT_RET_EXEMPT=0
#   C. the call-density test    EIGS_JIT_PROFIT_CALLPCT=100
#   D. the native-loop rule     (no knob: proved by bench_idxset's SPEED,
#                                which is what an absolute byte minimum
#                                destroyed -- 23 ms became 56 ms, and the
#                                JIT's own 2.5x bench silently became a
#                                no-op while every correctness gate stayed
#                                green)
#
# Oracle: EIGS_JIT_STATS=1's own `compiled=`/`demoted=` counters, and for D
# the wall time bench_idxset prints itself. Every check below asserts it read
# a NUMBER before comparing it, so a stats line that stops being emitted
# fails loudly instead of comparing two empty strings.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$TESTS_DIR/../src/eigenscript"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

stat_field() { # $1 field, $2.. env assignments; prints the number or nothing
  local f="$1"; shift
  env "$@" EIGS_JIT_STATS=1 "$EIGS" "$PROG" 2>&1 >/dev/null |
    grep -o "$f=[0-9]*" | head -1 | sed "s/$f=//"
}
num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; }

# A call-heavy program of SMALL callees: the shape the JIT measured as a net
# loss on ouroboros and EigenMiniSat. Each callee is a few bytecode bytes and
# is dominated by a call, so the gate must refuse or demote it.
cat > "$TMP/small_callees.eigs" <<'EOF'
define lo(x) as:
    return x - 1
define hi(x) as:
    return lo of x
define mid(x) as:
    return hi of x
n is 0
i is 0
loop while i < 60000:
    n is n + mid of i
    i is i + 1
print of f"small_callees n={n}"
EOF

# ---------------------------------------------------------------- arm A
PROG="$TMP/small_callees.eigs"
d_on=$(stat_field demoted)
d_off=$(stat_field demoted EIGS_JIT_PROFIT_MIN=0)
if ! num "$d_on" || ! num "$d_off"; then
  fail "no demoted= counter in the stats line (on='$d_on' off='$d_off') -- arms A-C below would be vacuous"
else
  if [ "$d_on" -gt 0 ]; then pass "arm A: the gate demotes small call-heavy callees (demoted=$d_on)"
  else fail "arm A: the gate demoted nothing on the shape it exists for"; fi
  if [ "$d_off" -eq 0 ]; then pass "arm A disabled (PROFIT_MIN=0) demotes nothing"
  else fail "arm A: PROFIT_MIN=0 still demoted $d_off chunks -- the knob does not disable the gate"; fi
fi

# ---------------------------------------------------------------- arm B
# A tiny callee that runs to its own RETURN natively: 100% of the call is
# handled in the thunk, so there is no interpreter resume to amortize and the
# byte minimum must not apply. Disabling the exemption must compile FEWER
# chunks -- if the count does not move, the exemption is not load-bearing.
cat > "$TMP/tiny_ret.eigs" <<'EOF'
define absv(x) as:
    if x < 0:
        return 0 - x
    return x
s is 0
i is 0 - 30000
loop while i < 30000:
    s is s + absv of i
    i is i + 1
print of f"tiny_ret s={s}"
EOF
PROG="$TMP/tiny_ret.eigs"
c_ret=$(stat_field compiled)
c_noret=$(stat_field compiled EIGS_JIT_PROFIT_RET_EXEMPT=0)
if ! num "$c_ret" || ! num "$c_noret"; then
  fail "arm B: no compiled= counter (exempt='$c_ret' plain='$c_noret')"
elif [ "$c_ret" -gt "$c_noret" ]; then
  pass "arm B: the RETURN exemption compiles a small full-return callee ($c_ret vs $c_noret)"
else
  fail "arm B: turning the RETURN exemption off changed nothing ($c_ret vs $c_noret) -- the arm is untested"
fi

# ---------------------------------------------------------------- arm C
# The call-density test withdraws the RETURN exemption from prefixes that are
# mostly OP_CALL -- measured 1.9x SLOWER than the interpreter on that shape.
# small_callees.eigs is exactly it, so raising the density ceiling to 100%
# must let MORE chunks through.
PROG="$TMP/small_callees.eigs"
c_dense=$(stat_field compiled)
c_nodense=$(stat_field compiled EIGS_JIT_PROFIT_CALLPCT=100)
if ! num "$c_dense" || ! num "$c_nodense"; then
  fail "arm C: no compiled= counter (gated='$c_dense' ungated='$c_nodense')"
elif [ "$c_nodense" -gt "$c_dense" ]; then
  pass "arm C: the call-density test refuses call-dominated prefixes ($c_dense vs $c_nodense ungated)"
else
  fail "arm C: CALLPCT=100 compiled no more than the default ($c_nodense vs $c_dense) -- the arm is untested"
fi

# ---------------------------------------------------------------- arm D
# bench_idxset is one thunk over a ~75-byte loop body run 100k times from a
# handful of entries. Judged on bytes-per-entry it looks tiny and gets
# demoted; judged on whether it COMPLETES its loop body it is the JIT's best
# case. This is a SPEED check because that is how the regression presented --
# stats, jit_diff and the whole suite stayed green while the 2.5x became 1.0x.
ms() { env "$@" "$EIGS" "$TESTS_DIR/bench_idxset.eigs" 2>/dev/null |
       sed -n 's/.*writes: \([0-9]*\)\..*/\1/p' | head -1; }
t_on=$(ms); t_off=$(ms EIGS_JIT_OFF=1)
if ! num "$t_on" || ! num "$t_off" || [ "$t_on" -le 0 ]; then
  fail "arm D: bench_idxset printed no timing (on='$t_on' off='$t_off')"
elif [ $((t_off * 10)) -gt $((t_on * 15)) ]; then
  pass "arm D: a looping thunk keeps its win (${t_off}ms interpreted vs ${t_on}ms JIT)"
else
  fail "arm D: the looping thunk lost its win (${t_off}ms interpreted vs ${t_on}ms JIT, want >= 1.5x) -- the native-loop rule is gone"
fi
