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
if echo "$out" | grep -q "^io|read_text: '/dev/stdin' is 10485761 bytes, over the 10485760-byte cap$"; then
    pass 'an over-cap stream stops at cap+1 and raises io'
else
    fail "stream cap: $out"
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

# Produce a genuine over-cap size verdict, then hand-edit its N value.  Every
# case must be refused as EK_IO rather than reaching a floating-to-integer cast.
EIGS_TRACE="$TMP/size.tape" sh -c "head -c 10485761 /dev/zero | '$BIN' '$TMP/cap.eigs'" >/dev/null 2>&1
valid=1
for bad in nan 1.5 -1 1e100; do
    sed -E "s/(N [0-9]+ read_text=)[^[:space:]]+/\\1$bad/" "$TMP/size.tape" >"$TMP/bad.tape"
    out=$(EIGS_REPLAY="$TMP/bad.tape" "$BIN" "$TMP/cap.eigs" </dev/null 2>&1)
    echo "$out" | grep -q '^io|read_text: replay record size is not an exact integer in range; refusing to replay$' || valid=0
done
[ "$valid" = 1 ] && pass 'non-finite, fractional, negative, and out-of-range taped sizes are refused' || fail 'invalid taped size verdict was converted'
