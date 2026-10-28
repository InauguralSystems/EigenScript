#!/usr/bin/env bash
# #1845 step 2: path readers fall back to a bounded, chunked EOF read when
# seek/tell cannot size a pipe or FIFO.  Their tape boundary includes the
# bytes, and hostile taped sizes are validated before conversion (#1914).
set -u
BIN=${EIGS_BIN:-../src/eigenscript}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; }

cat >"$TMP/text.eigs" <<'EOF'
s is read_text of "/dev/stdin"
print of f"{len of s}|{s}"
EOF
out=$(printf 'pipe text' | "$BIN" "$TMP/text.eigs" 2>&1)
[ "$out" = '9|pipe text' ] && pass 'read_text reads a /dev/stdin pipe to EOF' || fail "read_text pipe: $out"

cat >"$TMP/bytes.eigs" <<'EOF'
b is read_bytes of "/dev/stdin"
print of b
EOF
out=$(printf '\000\001\377' | "$BIN" "$TMP/bytes.eigs" 2>&1)
[ "$out" = '[0, 1, 255]' ] && pass 'read_bytes reads binary /dev/stdin to EOF' || fail "read_bytes pipe: $out"

mkfifo "$TMP/input.fifo"
cat >"$TMP/fifo.eigs" <<EOF
s is read_text of "$TMP/input.fifo"
print of s
EOF
(printf 'fifo payload' >"$TMP/input.fifo") &
out=$("$BIN" "$TMP/fifo.eigs" 2>&1)
wait
[ "$out" = 'fifo payload' ] && pass 'read_text reads a named FIFO to EOF' || fail "FIFO: $out"

cat >"$TMP/cap.eigs" <<'EOF'
try:
    s is read_text of "/dev/stdin"
catch e:
    print of f"{e.kind}|{e.message}"
EOF
out=$(head -c 10485761 /dev/zero | "$BIN" "$TMP/cap.eigs" 2>&1)
if echo "$out" | grep -q "^io|read_text: '/dev/stdin' is 10485761 bytes, over the 10485760-byte cap — pass read_text of \[path, max_bytes\] (hard ceiling 536870912) to raise it$"; then
    pass 'an over-cap stream stops at cap+1 and raises io'
else
    fail "stream cap: $out"
fi

# A stream has only proved that it crossed the cap; unlike stat/ftell it does
# not know the producer's total size.  The taped error must preserve that
# non-exact diagnostic byte for byte.
EIGS_TRACE="$TMP/cap.tape" sh -c "head -c 10485761 /dev/zero | '$BIN' '$TMP/cap.eigs'" >"$TMP/cap.record" 2>&1
EIGS_REPLAY="$TMP/cap.tape" "$BIN" "$TMP/cap.eigs" </dev/null >"$TMP/cap.replay" 2>&1
if cmp -s "$TMP/cap.record" "$TMP/cap.replay" &&
   grep -q "^io|read_text: '/dev/stdin' is 10485761 bytes, over the 10485760-byte cap — pass read_text of \[path, max_bytes\] (hard ceiling 536870912) to raise it$" "$TMP/cap.replay"; then
    pass 'stream over-cap replay preserves the non-exact message byte for byte'
else
    fail "stream cap replay: recorded='$(cat "$TMP/cap.record")' replayed='$(cat "$TMP/cap.replay")'"
fi

TAPE="$TMP/read.tape"
recorded=$(EIGS_TRACE="$TAPE" sh -c "printf 'recorded input' | '$BIN' '$TMP/text.eigs'" 2>&1)
different=$(printf 'different live input' | EIGS_REPLAY="$TAPE" "$BIN" "$TMP/text.eigs" 2>&1)
none=$(EIGS_REPLAY="$TAPE" "$BIN" "$TMP/text.eigs" </dev/null 2>&1)
if [ "$recorded" = "$different" ] && [ "$recorded" = "$none" ] && [ "$recorded" = '14|recorded input' ]; then
    pass 'pipe bytes replay without consulting changed or empty stdin'
else
    fail "stream replay: rec='$recorded' changed='$different' none='$none'"
fi

# Produce a genuine regular-file over-cap size verdict, then hand-edit its N
# value.  Finite but invalid sizes reach the reader's typed validation.
head -c 10485761 /dev/zero >"$TMP/big"
cat >"$TMP/regular-cap.eigs" <<EOF
try:
    s is read_text of "$TMP/big"
catch e:
    print of f"{e.kind}|{e.message}"
EOF
EIGS_TRACE="$TMP/size.tape" "$BIN" "$TMP/regular-cap.eigs" >/dev/null 2>&1
valid=1
for bad in 1.5 -1 1e100; do
    sed -E "s/(N [0-9]+ read_text=)[^[:space:]]+/\\1$bad/" "$TMP/size.tape" >"$TMP/bad.tape"
    out=$(EIGS_REPLAY="$TMP/bad.tape" "$BIN" "$TMP/cap.eigs" </dev/null 2>&1)
    echo "$out" | grep -q '^io|read_text: replay record size is not an exact integer in range; refusing to replay$' || valid=0
done
[ "$valid" = 1 ] && pass 'fractional, negative, and out-of-range taped sizes are refused by the reader' || fail 'invalid taped size verdict was converted'

# Non-finite numbers are corrupt in every N record, not merely reader sizes.
# The common tape parser must name and reject the token before it can become a
# language VAL_NUM.  Exercise both a reader record and an unrelated builtin.
boundary=1
for bad in nan inf; do
    sed -E "s/(N [0-9]+ read_text=)[^[:space:]]+/\\1$bad/" "$TMP/size.tape" >"$TMP/bad.tape"
    out=$(EIGS_REPLAY="$TMP/bad.tape" "$BIN" "$TMP/regular-cap.eigs" 2>&1)
    echo "$out" | grep -q "malformed v[0-9][0-9]* stream id or N value '$bad'; refusing to replay" || boundary=0
done
cat >"$TMP/random.eigs" <<'EOF'
print of (random of null)
EOF
EIGS_TRACE="$TMP/random.tape" "$BIN" "$TMP/random.eigs" >/dev/null 2>&1
sed -E 's/(N [0-9]+ random=)[^[:space:]]+/\1nan/' "$TMP/random.tape" >"$TMP/random-nan.tape"
out=$(EIGS_REPLAY="$TMP/random-nan.tape" "$BIN" "$TMP/random.eigs" 2>&1)
echo "$out" | grep -q "malformed v[0-9][0-9]* stream id or N value 'nan'; refusing to replay" || boundary=0
[ "$boundary" = 1 ] && pass 'nan and infinity are refused at the common tape boundary for reader and non-reader records' || fail "non-finite tape number crossed the boundary: $out"
