#!/bin/bash
# Replay tape tests for the eigenscript binary (Item 1: parse_value
# containers). Records a tape under EIGS_TRACE, then re-runs the script
# under EIGS_REPLAY with the underlying nondet source mutated — replayed
# output must match the recording.
#
# Run directly or from run_all_tests.sh. Prints a summary line:
#   REPLAY: N passed, M failed
# Exit code: 0 if all pass, 1 if any fail.

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$TESTS_DIR/.." && pwd)/src"
EIGS="$SRC_DIR/eigenscript"

PASS=0
FAIL=0
TMPDIR=$(mktemp -d -t eigs_replay.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

if [ ! -x "$EIGS" ]; then
    echo "  FAIL: eigenscript binary not found at $EIGS"
    echo "REPLAY: 0 passed, 1 failed"
    exit 1
fi

# ---- List replay (read_bytes returns VAL_LIST of nums) ----
INPUT="$TMPDIR/in.bin"
printf 'ABC' > "$INPUT"

cat > "$TMPDIR/p_list.eigs" <<EOF
print of (read_bytes of "$INPUT")
EOF

TAPE_L="$TMPDIR/list.tape"
REC_L=$(EIGS_TRACE="$TAPE_L" "$EIGS" "$TMPDIR/p_list.eigs" 2>&1)

# Mutate the underlying source — replay must still return the recorded list.
printf 'XYZ' > "$INPUT"
REP_L=$(EIGS_REPLAY="$TAPE_L" "$EIGS" "$TMPDIR/p_list.eigs" 2>&1)

if [ "$REC_L" = "[65, 66, 67]" ] && [ "$REP_L" = "[65, 66, 67]" ]; then
    ok "list replay: read_bytes returns recorded list under EIGS_REPLAY"
else
    fail "list replay" "rec='$REC_L' rep='$REP_L'"
fi

# ---- Buffer replay (read_bytes_buf returns VAL_BUFFER) ----
printf '\x01\x02\x03' > "$INPUT"

cat > "$TMPDIR/p_buf.eigs" <<EOF
b is read_bytes_buf of "$INPUT"
print of b[0]
print of b[1]
print of b[2]
EOF

TAPE_B="$TMPDIR/buf.tape"
REC_B=$(EIGS_TRACE="$TAPE_B" "$EIGS" "$TMPDIR/p_buf.eigs" 2>&1)

printf '\xff\xfe\xfd' > "$INPUT"
REP_B=$(EIGS_REPLAY="$TAPE_B" "$EIGS" "$TMPDIR/p_buf.eigs" 2>&1)

EXPECTED_B=$'1\n2\n3'
if [ "$REC_B" = "$EXPECTED_B" ] && [ "$REP_B" = "$EXPECTED_B" ]; then
    ok "buffer replay: read_bytes_buf restored as VAL_BUFFER (b[…] disambiguator)"
else
    fail "buffer replay" "rec='$REC_B' rep='$REP_B'"
fi

# ---- #411: every tape opens with a version header ----
# Handcrafted tapes below reuse the real header off the recorded tape, so
# they stay valid when the format or runtime version bumps.
VHDR=$(head -1 "$TAPE_L")
if echo "$VHDR" | grep -Eq '^V [0-9][0-9]* .'; then
    ok "version header: recorded tape starts with 'V <format> <runtime>'"
else
    fail "version header" "first line='$VHDR'"
fi

# ---- Dict replay (handcrafted tape — no nondet builtin returns dicts) ----
# The record must be a kind its builtin can return (#1637: k_tape_kinds in
# src/trace.c). No core taped builtin returns a dict, so the dict rides inside
# `ls`'s list.
cat > "$TMPDIR/p_dict.eigs" <<'EOF'
v is ls of "."
print of v[0]
EOF

cat > "$TMPDIR/dict.tape" <<EOF
$VHDR
B 0 1 1 0 root -
N 0 ls=[{"a": 1, "b": "two", "c": null}]
EOF

REP_D=$(EIGS_REPLAY="$TMPDIR/dict.tape" "$EIGS" "$TMPDIR/p_dict.eigs" 2>/dev/null)

if [ "$REP_D" = '{"a": 1, "b": "two", "c": null}' ]; then
    ok "dict replay: handcrafted N record materializes as VAL_DICT"
else
    fail "dict replay" "out='$REP_D'"
fi

# ---- Nested replay (list containing dict and buffer) ----
cat > "$TMPDIR/p_nested.eigs" <<'EOF'
v is ls of "."
print of v[0]
print of v[1]["k"]
print of v[2][1]
EOF

# Outer list: [{"k": 42}, {"k": "ok"}, b[10, 20, 30]]
cat > "$TMPDIR/nested.tape" <<EOF
$VHDR
B 0 1 1 0 root -
N 0 ls=[{"k": 42}, {"k": "ok"}, b[10, 20, 30]]
EOF

REP_N=$(EIGS_REPLAY="$TMPDIR/nested.tape" "$EIGS" "$TMPDIR/p_nested.eigs" 2>/dev/null)
EXPECTED_N=$'{"k": 42}\nok\n20'

if [ "$REP_N" = "$EXPECTED_N" ]; then
    ok "nested replay: list[dict, dict, buffer] round-trip"
else
    fail "nested replay" "out='$REP_N' expected='$EXPECTED_N'"
fi

# ---- Strict mode: name mismatch is fatal (exit 3) ----
cat > "$TMPDIR/p_strict.eigs" <<'EOF'
r is random of null
print of r
EOF

cat > "$TMPDIR/strict.tape" <<EOF
$VHDR
B 0 1 1 0 root -
N 0 monotonic_ns=12345
EOF

# Lenient (default): warns on stderr, uses the recorded value anyway.
LEN_OUT=$(EIGS_REPLAY="$TMPDIR/strict.tape" "$EIGS" "$TMPDIR/p_strict.eigs" 2>/dev/null)
if [ "$LEN_OUT" = "12345" ]; then
    ok "lenient replay: mismatched name still serves recorded value"
else
    fail "lenient replay" "out='$LEN_OUT' expected='12345'"
fi

# Strict: same tape aborts with exit 3 and a diagnostic.
STRICT_ERR=$(EIGS_REPLAY="$TMPDIR/strict.tape" EIGS_REPLAY_STRICT=1 "$EIGS" "$TMPDIR/p_strict.eigs" 2>&1 >/dev/null)
STRICT_RC=$?
if [ "$STRICT_RC" = "3" ] && echo "$STRICT_ERR" | grep -q "replay name mismatch"; then
    ok "strict replay: name mismatch aborts with exit 3"
else
    fail "strict replay" "rc=$STRICT_RC err='$STRICT_ERR'"
fi

# ---- Non-replayable boundary (#148): subprocess/concurrency builtins ----
# Each of the seven builtins below must refuse to run under EIGS_REPLAY and
# raise a catchable runtime error rather than silently re-executing real
# side effects against a tape that has no host-side causal structure.
# #1072: the boundary check runs AFTER argument validation now (a wrong-typed
# call must be the same error in both modes), so every probe passes a
# Every probe passes a well-formed argument so validation cannot mask the replay boundary.
cat > "$TMPDIR/p_block.eigs" <<'EOF'
caught is 0
try:
    r is exec_capture of [["true"]]
catch e:
    caught is caught + 1
ch is channel of null
try:
    r is recv of ch
catch e:
    caught is caught + 1
try:
    r is try_recv of ch
catch e:
    caught is caught + 1
try:
    r is recv_timeout of [ch, 1]
catch e:
    caught is caught + 1
print of caught
EOF

# Header-only tape so replay is enabled but every builtin's TAKE returns 0 —
# the replay_blocks guard fires before TAKE on these builtins, so no record
# is consumed. The script just counts how many calls raised.
echo "$VHDR" > "$TMPDIR/block.tape"
BLOCK_OUT=$(EIGS_REPLAY="$TMPDIR/block.tape" "$EIGS" "$TMPDIR/p_block.eigs" 2>/dev/null)
if [ "$BLOCK_OUT" = "4" ]; then
    ok "replay-block: all 4 exec/channel builtins refuse under EIGS_REPLAY (#148)"
else
    fail "replay-block" "caught=$BLOCK_OUT (expected 4)"
fi

# ---- #683: clock_unix is a taped nondeterminism source ----
# Record a wall-clock read, then replay a full second later: the recorded
# epoch must win byte-for-byte (a live read would return a later time).
cat > "$TMPDIR/p_clock.eigs" <<'EOF'
print of (clock_unix of null)
EOF

TAPE_CU="$TMPDIR/clock.tape"
REC_CU=$(EIGS_TRACE="$TAPE_CU" "$EIGS" "$TMPDIR/p_clock.eigs" 2>&1)
sleep 1
REP_CU=$(EIGS_REPLAY="$TAPE_CU" "$EIGS" "$TMPDIR/p_clock.eigs" 2>&1)

if [ -n "$REC_CU" ] && [ "$REC_CU" = "$REP_CU" ] && grep -q '^N [0-9][0-9]* clock_unix=' "$TAPE_CU"; then
    ok "clock_unix replay: recorded epoch wins on replay (#683)"
else
    fail "clock_unix replay" "rec='$REC_CU' rep='$REP_CU'"
fi

# ---- #579: audio capture is a taped nondeterminism source ----
# Gated: needs a gfx build AND a working capture device (the dummy SDL
# driver provides a silent one; the CI dev image has no libSDL2, so this
# skips there and runs wherever SDL exists). Record a capture session,
# then replay it with the SDL driver deliberately broken — the recorded
# device id and sample buffers must be served off the tape (replay must
# never open or read a real device).
cat > "$TMPDIR/p_cap_probe.eigs" <<'EOF'
print of (audio_capture_open of [44100, 1])
EOF
CAP_PROBE=$(SDL_AUDIODRIVER=dummy "$EIGS" "$TMPDIR/p_cap_probe.eigs" 2>&1)

if ! echo "$CAP_PROBE" | grep -q "undefined variable" \
   && [ "$(echo "$CAP_PROBE" | tail -1)" != "0" ]; then
    cat > "$TMPDIR/p_cap.eigs" <<'EOF'
dev is audio_capture_open of [44100, 1]
print of (dev != 0)
chunk is audio_capture_read of null
tries is 0
loop while (len of chunk) == 0 and tries < 80:
    gfx_delay of 25
    chunk is audio_capture_read of null
    tries is tries + 1
print of (len of chunk)
print of chunk[0]
audio_capture_close of null
print of (audio_capture_read of null)
EOF

    TAPE_C="$TMPDIR/cap.tape"
    REC_C=$(SDL_AUDIODRIVER=dummy EIGS_TRACE="$TAPE_C" "$EIGS" "$TMPDIR/p_cap.eigs" 2>&1)
    # Replay with a nonexistent SDL audio driver: a live open would fail
    # (and a live read would return null), so matching output proves the
    # values came from the tape, not the device.
    REP_C=$(SDL_AUDIODRIVER=doesnotexist EIGS_REPLAY="$TAPE_C" "$EIGS" "$TMPDIR/p_cap.eigs" 2>&1)
    REC_LEN=$(echo "$REC_C" | sed -n '2p')

    if [ "$REC_C" = "$REP_C" ] && [ "$(echo "$REC_C" | sed -n '1p')" = "true" ] \
       && [ "${REC_LEN:-0}" -gt 0 ] && grep -q '^N [0-9][0-9]* audio_capture_read=b\[' "$TAPE_C"; then
        ok "capture replay: recorded mic session replays without a device (#579)"
    else
        fail "capture replay" "rec='$REC_C' rep='$REP_C'"
    fi
else
    echo "  SKIP: capture replay (no gfx build / no capture device)"
fi

# EigenStore's live file/handle family is an explicit replay boundary (#1242).
if bash "$TESTS_DIR/test_store_replay.sh" "$EIGS"; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi

echo
echo "REPLAY: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] && exit 0 || exit 1
