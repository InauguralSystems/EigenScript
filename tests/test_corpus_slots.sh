#!/bin/bash
# build_corpus slot mode: identifier encoding that can express a correct program.
#
# Frequency mode promotes the top-N identifiers by count and drops everything
# else onto ONE fallback token (bare TOK_IDENT). Measured on the 2026-07
# ecosystem corpus at top_n=256 that is 45.7% of all identifier occurrences —
# so distinct variables become indistinguishable and `total is total + items[i]`
# encodes as `<ident> is <ident> + <ident>[<ident>]`. No model can express
# "assign the variable I just read" through that, which is the property that
# separates well-formed output from correct output.
#
# Slot mode (optional 6th arg) instead gives every BUILTIN an exact token — the
# runtime's own registry decides, so the list cannot drift — and encodes each
# local as one of N reusable LRU slots. Locals are arbitrary by definition: any
# consistent renaming is an equally correct program, so only identity matters.
#
# The assertions below pin the three properties that make it lossless.

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$TESTS_DIR/../src/eigenscript"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d /tmp/eigs_slots_XXXXXX)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

cat > "$WORK/sample.eigs" <<'SRC'
define accumulate(total, items) as:
    for i in range of (len of items):
        total is total + items[i]
    return total
SRC

# NOTE: the driver deliberately defines a top-level function whose name also
# occurs in the corpus. Reading the LIVE global env to decide "is this a
# builtin?" cannot tell `_driver_helper` from `print`, so it would promote the
# driver's own helper to an exact token — which is what SL05 pins against.
cat > "$WORK/build.eigs" <<'DRV'
define _driver_helper(x) as:
    return x

a is args of null
files is [a[0] + "/sample.eigs"]
r is build_corpus of [files, 4, a[0] + "/s.bin", a[0] + "/v.json", a[0] + "/i.json", 8]
print of ("TOKENS " + (str of r[0]))
DRV

# `_driver_helper` must exist in the corpus too, or its absence from the vocab
# would prove nothing.
echo '_driver_helper is 1' >> "$WORK/sample.eigs"

if ! "$EIGS" "$WORK/build.eigs" "$WORK" >"$WORK/out.log" 2>&1; then
    fail "SL00 slot-mode build_corpus ran" "see $WORK/out.log"
    echo "CORPUSSLOTS: 0 passed, 1 failed"
    exit 1
fi
ok "SL00 slot-mode build_corpus ran"

# Decode the stream against the vocab and check the three properties.
cat > "$WORK/check.eigs" <<'CHK'
a is args of null
v is json_decode of (read_text of (a[0] + "/v.json"))
stream is tensor_load of (a[0] + "/s.bin")
base is v["base_vocab"]
fs is v["first_slot_id"]
nslot is v["slot_count"]
fb is v["structural_ids"]["ident_fallback"]

# 1. no identifier may fall back
nfb is 0
for i in range of (len of stream):
    if stream[i] == fb:
        nfb is nfb + 1
print of ("FALLBACK " + (str of nfb))

# 2. slots must stay inside the declared range
bad is 0
for i in range of (len of stream):
    t is stream[i]
    if t >= fs:
        if t >= (fs + nslot):
            bad is bad + 1
print of ("OUTOFRANGE " + (str of bad))

# 3. identity: `total` occurs 4x in the sample and must be ONE repeated token.
#    Count distinct ids that appear at least 3 times in the slot range.
counts is zeros of 64
for i in range of (len of stream):
    t is stream[i]
    if t >= fs:
        if t < (fs + nslot):
            counts[t - fs] is counts[t - fs] + 1
rep is 0
for i in range of nslot:
    if counts[i] >= 3:
        rep is rep + 1
print of ("REPEATED " + (str of rep))
print of ("SLOTCOUNT " + (str of nslot))
CHK

OUT=$("$EIGS" "$WORK/check.eigs" "$WORK" 2>/dev/null)
g() { printf '%s\n' "$OUT" | sed -n "s/^$1 //p"; }

if [ "$(g FALLBACK)" = "0" ]; then
    ok "SL01 slot mode emits ZERO fallback <ident> tokens"
else
    fail "SL01 slot mode still emits the fallback token" "count=$(g FALLBACK)"
fi

if [ "$(g OUTOFRANGE)" = "0" ]; then
    ok "SL02 every slot id lands inside [first_slot_id, +slot_count)"
else
    fail "SL02 slot id out of declared range" "count=$(g OUTOFRANGE)"
fi

# `total` appears 4x and `items` 3x — a repeated slot proves the LRU table
# returns the SAME token for the same name rather than a fresh one each time.
# Exactly two locals clear the 3-occurrence bar, so pin 2: `>= 1` would still
# pass with half the identity mapping broken, and identity is the one property
# this whole encoding exists to provide.
if [ "$(g REPEATED)" = "2" ]; then
    ok "SL03 both repeated locals keep ONE slot each (identity preserved)"
else
    fail "SL03 wrong number of reused slots — identity not preserved" "repeated=$(g REPEATED), want 2"
fi

# Regression guard: frequency mode (no 6th arg) must be untouched.
cat > "$WORK/freq.eigs" <<'FRQ'
a is args of null
files is [a[0] + "/sample.eigs"]
r is build_corpus of [files, 2, a[0] + "/sf.bin", a[0] + "/vf.json", a[0] + "/if.json"]
v is json_decode of (read_text of (a[0] + "/vf.json"))
print of ("SLOTS " + (str of v["slot_count"]))
FRQ
FOUT=$("$EIGS" "$WORK/freq.eigs" "$WORK" 2>/dev/null | sed -n 's/^SLOTS //p')
if [ "$FOUT" = "0" ]; then
    ok "SL04 frequency mode unchanged (slot_count 0 when no 6th arg)"
else
    fail "SL04 frequency mode changed" "slot_count=$FOUT"
fi

# The exact-token list must be the LANGUAGE's names, not the driver script's.
# Deciding this from the live global env cannot distinguish them — by the time
# build_corpus runs, the driver's own `define`s are bound in that same env — so
# `_driver_helper` would be handed an exact token beside `print` and `len`.
# Beyond being wrong, it makes the vocabulary depend on whichever script built
# the corpus: add a helper to the driver and every token id shifts, silently
# invalidating comparison against models trained on an earlier build.
cat > "$WORK/vocab.eigs" <<'VOC'
a is args of null
v is json_decode of (read_text of (a[0] + "/v.json"))
names is v["names"]
hit is 0
for i in range of (len of names):
    if names[i] == "_driver_helper":
        hit is 1
print of ("DRIVERLEAK " + (str of hit))
VOC
VOUT=$("$EIGS" "$WORK/vocab.eigs" "$WORK" 2>/dev/null | sed -n 's/^DRIVERLEAK //p')
if [ "$VOUT" = "0" ]; then
    ok "SL05 driver script's own functions stay OUT of the exact-token vocab"
else
    fail "SL05 driver-defined function leaked into the builtin vocabulary" "_driver_helper promoted"
fi

echo "CORPUSSLOTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
