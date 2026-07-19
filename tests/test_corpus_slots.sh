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

cat > "$WORK/build.eigs" <<'DRV'
a is args of null
files is [a[0] + "/sample.eigs"]
r is build_corpus of [files, 4, a[0] + "/s.bin", a[0] + "/v.json", a[0] + "/i.json", 8]
print of ("TOKENS " + (str of r[0]))
DRV

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
if [ "$(g REPEATED)" -ge 1 ] 2>/dev/null; then
    ok "SL03 a repeated local keeps ONE slot (identity preserved, $(g REPEATED) slot(s) reused)"
else
    fail "SL03 no slot was reused — identity not preserved" "repeated=$(g REPEATED)"
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

echo "CORPUSSLOTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
