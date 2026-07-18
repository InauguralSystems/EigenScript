#!/bin/bash
# eigen_generate top-p (nucleus) sampling.
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
cleanup() { rm -f "$MODEL" "$HARNESS" /tmp/eigs_tp_*.log; }
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

echo "TOPP: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
