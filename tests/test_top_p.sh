#!/bin/bash
# eigen_generate sampling: the top-p (nucleus) policy, and the trace-tape
# invariant its nondeterminism owes (#960) — plus the random_normal fills that
# share the sampler's RNG stream.
#
# Testing this needs care: generation draws from a global rand(), so two calls
# with the SAME policy already disagree on most positions (measured 3/40
# identical). Comparing two token sequences therefore proves nothing about the
# sampling policy -- an earlier version of this check "verified" top-p by
# observing 0/40 matches, which is indistinguishable from the same-policy
# control.
#
# What IS robust is the statistical signature. On a near-uniform (untrained)
# model, top-p keeps every token up to a cumulative mass of p while top-k keeps
# a fixed few, so the two policies emit visibly different numbers of DISTINCT
# tokens over a long generation. That is a property of the candidate set, not
# of any particular rand() draw. On the vocab=1109 model the split is 61 vs 257
# distinct in 300 tokens.
#
# Runs only when the binary is built with EIGENSCRIPT_EXT_MODEL=1.

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$TESTS_DIR/../src/eigenscript"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

MODEL=/tmp/eigs_tp_tiny.json
HARNESS=/tmp/eigs_tp_harness.eigs
TAPE=/tmp/eigs_tp_gen.tape
REPLAY_MODEL=/tmp/eigs_tp_tiny_replay.json
cleanup() { rm -f "$MODEL" "$HARNESS" "$TAPE" "$REPLAY_MODEL" /tmp/eigs_tp_*.log; }
trap cleanup EXIT

if ! "$EIGS" "$TESTS_DIR/gen_tiny_model.eigs" > "$MODEL" 2>/tmp/eigs_tp_gen.log; then
    fail "TP00 generate tiny model" "see /tmp/eigs_tp_gen.log"
    echo "TOPP: 0 passed, 1 failed"
    exit 1
fi

# vocab=8, so the top-k=40 default clamps to "keep everything" and a restrictive
# top-p must keep strictly fewer. 400 tokens makes the distinct counts stable.
cat > "$HARNESS" <<'EIGS'
ck is args of null
r is eigen_model_load of ck[0]
define ndistinct(ids) as:
    seen is zeros of 64
    d is 0
    for i in range of (len of ids):
        t is ids[i]
        if t >= 0:
            if t < 64:
                if seen[t] == 0:
                    seen[t] is 1
                    d is d + 1
    return d
a is eigen_generate of [[1, 2, 3], 1.0, 400]
b is eigen_generate of [[1, 2, 3], 1.0, 400, 0.3]
print of ("K " + (str of (ndistinct of a)))
print of ("P " + (str of (ndistinct of b)))
print of ("PLEN " + (str of (len of b)))
EIGS

OUT=$("$EIGS" "$HARNESS" "$MODEL" 2>/dev/null)
K=$(printf '%s\n' "$OUT" | sed -n 's/^K //p')
P=$(printf '%s\n' "$OUT" | sed -n 's/^P //p')
PLEN=$(printf '%s\n' "$OUT" | sed -n 's/^PLEN //p')

if [ -z "$K" ] || [ -z "$P" ]; then
    fail "TP01 both sampling policies produced output" "K='$K' P='$P'"
    echo "TOPP: $PASS passed, $((FAIL)) failed"
    exit 1
fi
ok "TP01 both sampling policies produced output"

if [ "$PLEN" = "400" ]; then
    ok "TP02 top-p generated the requested token count"
else
    fail "TP02 top-p token count" "expected 400, got $PLEN"
fi

# The load-bearing assertion: a restrictive nucleus must narrow the candidate
# set. If top_p were ignored, this collapses to the same policy twice and the
# counts land equal.
if [ "$P" -lt "$K" ]; then
    ok "TP03 top-p=0.3 narrows the candidate set vs top-k ($P < $K distinct)"
else
    fail "TP03 top-p did not narrow the candidate set" "top-k=$K distinct, top-p=$P distinct"
fi

# top_p outside (0,1) must fall back to the historical top-k path rather than
# emptying the candidate set or dividing by zero.
cat > "$HARNESS" <<'EIGS'
ck is args of null
r is eigen_model_load of ck[0]
for p in [0.0, 1.0, 2.0, 0 - 1.0]:
    g is eigen_generate of [[1, 2, 3], 1.0, 20, p]
    print of ("N " + (str of (len of g)))
EIGS
OOR=$("$EIGS" "$HARNESS" "$MODEL" 2>/dev/null | sed -n 's/^N //p' | sort -u)
if [ "$OOR" = "20" ]; then
    ok "TP04 out-of-range top_p falls back to top-k and still generates"
else
    fail "TP04 out-of-range top_p broke generation" "lengths: $(printf '%s ' $OOR)"
fi

# ---- #960: sampled tokens must ride the trace tape --------------------------
# Generation at temperature > 0 is a nondeterministic builtin return, so it
# belongs on the tape like random/random_int: ONE `N eigen_generate=` record
# carrying the whole emitted token list (the individual draws are an
# implementation detail; the token list is what the script observes), served
# back verbatim under EIGS_REPLAY.
#
# The three checks below pin the invariant end to end. TP07's control is
# load-bearing: without TP06 proving the seed actually moves the tokens, a
# replay that quietly re-sampled would still "match" whenever the sampler
# happened to be pinned, so the equality alone proves nothing.
cp "$MODEL" "$REPLAY_MODEL"

gen_harness() {   # $1 = seed
    cat > "$HARNESS" <<EIGS
seed_random of $1
r is eigen_model_load of "$REPLAY_MODEL"
g is eigen_generate of [[1, 2, 3], 1.0, 12]
print of "G:"
print of g
EIGS
}
gline() { printf '%s\n' "$1" | grep -A1 '^G:$' | tail -1; }

gen_harness 7
rm -f "$TAPE"
REC=$(gline "$(EIGS_TRACE="$TAPE" "$EIGS" "$HARNESS" 2>/dev/null)")

NREC=$(grep -c '^N eigen_generate=' "$TAPE" 2>/dev/null || true)
RECVAL=$(sed -n 's/^N eigen_generate=//p' "$TAPE" 2>/dev/null | head -1)
# 12 tokens in one list record => 11 separators. A per-token record scheme
# lands 12 records of one token each and fails on the count instead.
NSEP=$(printf '%s' "$RECVAL" | tr -cd ',' | wc -c | tr -d '[:space:]')
if [ "$NREC" = "1" ] && [ "$NSEP" = "11" ]; then
    ok "TP05 one N record carries the whole 12-token generation"
else
    fail "TP05 eigen_generate nondet record" "records=$NREC record='$RECVAL'"
fi

gen_harness 4242
LIVE=$(gline "$("$EIGS" "$HARNESS" 2>/dev/null)")
REP=$(gline "$(EIGS_REPLAY="$TAPE" "$EIGS" "$HARNESS" 2>/dev/null)")

if [ -n "$REC" ] && [ "$LIVE" != "$REC" ]; then
    ok "TP06 a different seed samples different tokens (TP07 is not vacuous)"
else
    fail "TP06 seed control" "seed 7='$REC' seed 4242='$LIVE'"
fi

if [ -n "$REC" ] && [ "$REP" = "$REC" ]; then
    ok "TP07 replay returns the recorded tokens under a different seed"
else
    fail "TP07 replay diverged from the tape" "recorded='$REC' replayed='$REP'"
fi

# With the checkpoint gone the live path cannot generate at all, so a matching
# replay proves the tape is taken BEFORE the model is consulted — the same
# "replay last night's run with the world gone" contract the net_* family has.
rm -f "$REPLAY_MODEL"
REP_NOMODEL=$(gline "$(EIGS_REPLAY="$TAPE" "$EIGS" "$HARNESS" 2>/dev/null)")
if [ -n "$REC" ] && [ "$REP_NOMODEL" = "$REC" ]; then
    ok "TP08 replay serves the recorded tokens with the model file deleted"
else
    fail "TP08 replay still needs the model" "recorded='$REC' replayed='$REP_NOMODEL'"
fi

# ---- #960 residual: the randn tensor fills draw from the same stream --------
# seed_random seeds drand48 only, so a raw libc rand() fill is unpinnable from
# script: the same seed twice yields different numbers. TP10 keeps TP09 honest
# — a fill that ignored the seed entirely (or returned constants) would satisfy
# TP09 alone.
cat > "$HARNESS" <<'EIGS'
seed_random of 5
print of "RN1:"
print of (random_normal of [4, 1.0])
seed_random of 5
print of "RN2:"
print of (random_normal of [4, 1.0])
seed_random of 6
print of "RN3:"
print of (random_normal of [4, 1.0])
EIGS
RN_OUT=$("$EIGS" "$HARNESS" 2>/dev/null)
RN1=$(printf '%s\n' "$RN_OUT" | grep -A1 '^RN1:$' | tail -1)
RN2=$(printf '%s\n' "$RN_OUT" | grep -A1 '^RN2:$' | tail -1)
RN3=$(printf '%s\n' "$RN_OUT" | grep -A1 '^RN3:$' | tail -1)

if [ -n "$RN1" ] && [ "$RN1" = "$RN2" ]; then
    ok "TP09 random_normal repeats exactly after the same seed_random"
else
    fail "TP09 random_normal ignores seed_random" "first='$RN1' second='$RN2'"
fi

if [ -n "$RN1" ] && [ "$RN1" != "$RN3" ]; then
    ok "TP10 a different seed moves random_normal (TP09 is not vacuous)"
else
    fail "TP10 random_normal is seed-independent" "seed 5='$RN1' seed 6='$RN3'"
fi

echo "TOPP: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
