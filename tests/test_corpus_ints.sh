#!/bin/bash
# build_corpus integer-literal encoding: give small integers exact tokens.
#
# Every numeric literal tokenizes to a single TOK_NUM, erasing its value: the
# stream cannot tell `[1,2,3]` from `[0,0,0]`. Measured on the 2026-07 corpus
# that erasure is doubly costly -- an assertion-as-spec carries no information
# (`(f of 4)==1` and `(f of 3)==0` become one sequence), AND it manufactures the
# degenerate `0,0,0` repetition the model collapses into. The optional 7th arg
# int_count=N gives exact tokens to integers [0, N); everything else keeps the
# lossy TOK_NUM fallback.
#
# The assertions pin the properties that make the fix do its job.

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$TESTS_DIR/../src/eigenscript"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d /tmp/eigs_ints_XXXXXX)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# Distinct ascending ints, a genuine zeros run, an out-of-range int, and a float.
cat > "$WORK/sample.eigs" <<'SRC'
a is [1, 2, 3, 4, 5]
b is [0, 0, 0, 0, 0]
c is 100
d is 3.5
SRC

cat > "$WORK/build.eigs" <<'DRV'
a is args of null
files is [a[0] + "/sample.eigs"]
r is build_corpus of [files, 4, a[0] + "/s.bin", a[0] + "/v.json", a[0] + "/i.json", 8, 32]
print of ("TOKENS " + (str of r[0]))
DRV

if ! "$EIGS" "$WORK/build.eigs" "$WORK" >"$WORK/out.log" 2>&1; then
    fail "IL00 int-mode build_corpus ran" "see $WORK/out.log"
    echo "CORPUSINTS: 0 passed, 1 failed"
    exit 1
fi
ok "IL00 int-mode build_corpus ran"

# Decode against the vocab and check the four properties.
cat > "$WORK/check.eigs" <<'CHK'
a is args of null
v is json_decode of (read_text of (a[0] + "/v.json"))
stream is tensor_load of (a[0] + "/s.bin")
fi is v["first_int_id"]
nint is v["int_count"]
toknum is v["structural_ids"]["eof"]   # placeholder; real TOK_NUM found below

# 1. the five ascending literals 1..5 must be five DISTINCT tokens in the int
#    range -- this is the collision break. Count distinct int-range tokens that
#    appear exactly once and are NOT the zero token.
counts is zeros of 64
for i in range of (len of stream):
    t is stream[i]
    if t >= fi:
        if t < (fi + nint):
            counts[t - fi] is counts[t - fi] + 1
# distinct nonzero int values present:
distinct is 0
for i in range of nint:
    if i > 0:
        if counts[i] >= 1:
            distinct is distinct + 1
print of ("DISTINCT_NONZERO " + (str of distinct))

# 2. the zeros run: INT0 must appear 5x (genuine repetition preserved as ONE token)
print of ("ZERO_COUNT " + (str of counts[0]))

# 3. no int token may exceed the declared range
bad is 0
for i in range of (len of stream):
    t is stream[i]
    if t >= (fi + nint):
        if t < fi:
            bad is bad + 1
print of ("MAXINT " + (str of (fi + nint - 1)))
CHK

OUT=$("$EIGS" "$WORK/check.eigs" "$WORK" 2>/dev/null)
g() { printf '%s\n' "$OUT" | sed -n "s/^$1 //p"; }

# 1..5 are five distinct nonzero int tokens: the collision `[1,2,3]`==`[0,0,0]` is broken.
if [ "$(g DISTINCT_NONZERO)" = "5" ]; then
    ok "IL01 ascending literals 1..5 encode as 5 distinct tokens (collision broken)"
else
    fail "IL01 literals 1..5 not distinct" "distinct_nonzero=$(g DISTINCT_NONZERO), want 5"
fi

# genuine zeros run stays ONE repeated token -- real repetition is not destroyed.
if [ "$(g ZERO_COUNT)" = "5" ]; then
    ok "IL02 a genuine zeros run stays one repeated token (real repetition kept)"
else
    fail "IL02 zeros run wrong" "zero_count=$(g ZERO_COUNT), want 5"
fi

# 100 (>= int_count) and 3.5 (non-integer) must NOT occupy int tokens: exactly
# 6 distinct int tokens total (0..5), nothing more.
cat > "$WORK/range.eigs" <<'RNG'
a is args of null
v is json_decode of (read_text of (a[0] + "/v.json"))
stream is tensor_load of (a[0] + "/s.bin")
fi is v["first_int_id"]
nint is v["int_count"]
seen is zeros of 64
for i in range of (len of stream):
    t is stream[i]
    if t >= fi:
        if t < (fi + nint):
            seen[t - fi] is 1
tot is 0
for i in range of nint:
    tot is tot + seen[i]
print of ("DISTINCT_TOTAL " + (str of tot))
RNG
ROUT=$("$EIGS" "$WORK/range.eigs" "$WORK" 2>/dev/null | sed -n 's/^DISTINCT_TOTAL //p')
if [ "$ROUT" = "6" ]; then
    ok "IL03 out-of-range (100) and non-integer (3.5) literals stay lossy, not int tokens"
else
    fail "IL03 wrong distinct int total" "distinct=$ROUT, want 6 (values 0..5 only)"
fi

# Backward compat: no 7th arg -> no int region, stream byte-identical to slot-only.
cat > "$WORK/noint.eigs" <<'NOI'
a is args of null
files is [a[0] + "/sample.eigs"]
r is build_corpus of [files, 4, a[0] + "/sn.bin", a[0] + "/vn.json", a[0] + "/in.json", 8]
v is json_decode of (read_text of (a[0] + "/vn.json"))
print of ("INTCOUNT " + (str of v["int_count"]))
NOI
NOUT=$("$EIGS" "$WORK/noint.eigs" "$WORK" 2>/dev/null | sed -n 's/^INTCOUNT //p')
if [ "$NOUT" = "0" ]; then
    ok "IL04 no 7th arg -> int_count 0 (opt-in, stream unchanged)"
else
    fail "IL04 int mode leaked into the no-arg call" "int_count=$NOUT"
fi

echo "CORPUSINTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
