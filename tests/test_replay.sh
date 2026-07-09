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
if echo "$VHDR" | grep -Eq '^V [0-9]+ .'; then
    ok "version header: recorded tape starts with 'V <format> <runtime>'"
else
    fail "version header" "first line='$VHDR'"
fi

# ---- Dict replay (handcrafted tape — no nondet builtin returns dicts) ----
# trace_replay_take is lenient on name mismatch (warns, uses anyway),
# so we craft the N record under any nondet name and bind it.
cat > "$TMPDIR/p_dict.eigs" <<'EOF'
v is env_get of "EIGS_REPLAY_TEST_KEY_DOES_NOT_EXIST"
print of v
EOF

cat > "$TMPDIR/dict.tape" <<EOF
$VHDR
N env_get={"a": 1, "b": "two", "c": null}
EOF

REP_D=$(EIGS_REPLAY="$TMPDIR/dict.tape" "$EIGS" "$TMPDIR/p_dict.eigs" 2>/dev/null)

if [ "$REP_D" = '{"a": 1, "b": "two", "c": null}' ]; then
    ok "dict replay: handcrafted N record materializes as VAL_DICT"
else
    fail "dict replay" "out='$REP_D'"
fi

# ---- Nested replay (list containing dict and buffer) ----
cat > "$TMPDIR/p_nested.eigs" <<'EOF'
v is env_get of "EIGS_REPLAY_TEST_KEY_NESTED"
print of v[0]
print of v[1]["k"]
print of v[2][1]
EOF

# Outer list: [{"k": 42}, {"k": "ok"}, b[10, 20, 30]]
cat > "$TMPDIR/nested.tape" <<EOF
$VHDR
N env_get=[{"k": 42}, {"k": "ok"}, b[10, 20, 30]]
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
N monotonic_ns=12345
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
cat > "$TMPDIR/p_block.eigs" <<'EOF'
caught is 0
try:
    r is exec_capture of [["true"]]
catch e:
    caught is caught + 1
try:
    r is proc_spawn of ["true"]
catch e:
    caught is caught + 1
try:
    r is proc_write of [1, "x"]
catch e:
    caught is caught + 1
try:
    r is proc_read_line of 0
catch e:
    caught is caught + 1
try:
    r is proc_read of [0, 16]
catch e:
    caught is caught + 1
try:
    r is proc_close of 0
catch e:
    caught is caught + 1
try:
    r is proc_wait of 1
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
if [ "$BLOCK_OUT" = "10" ]; then
    ok "replay-block: all 10 subprocess/channel builtins refuse under EIGS_REPLAY (#148)"
else
    fail "replay-block" "caught=$BLOCK_OUT (expected 10)"
fi

# And the error text identifies the boundary so the user can find docs/TRACE.md.
cat > "$TMPDIR/p_block_msg.eigs" <<'EOF'
try:
    r is proc_spawn of ["true"]
catch e:
    print of e
EOF
BLOCK_MSG=$(EIGS_REPLAY="$TMPDIR/block.tape" "$EIGS" "$TMPDIR/p_block_msg.eigs" 2>/dev/null)
if echo "$BLOCK_MSG" | grep -q "not replayable under EIGS_REPLAY" \
   && echo "$BLOCK_MSG" | grep -q "subprocess/concurrency"; then
    ok "replay-block: error text names the replay boundary"
else
    fail "replay-block message" "out='$BLOCK_MSG'"
fi

# ---- #411: version-and-reject — every mismatch class refuses loudly ----
# Control first: the untampered tape must still replay (proves the checks
# below fail because of the tamper, not a broken fixture), on both tiers.
printf 'ABC' > "$INPUT"
GOOD=$(EIGS_TRACE="$TMPDIR/v.tape" "$EIGS" "$TMPDIR/p_list.eigs" 2>&1)
printf 'XYZ' > "$INPUT"
CTRL=$(EIGS_REPLAY="$TMPDIR/v.tape" "$EIGS" "$TMPDIR/p_list.eigs" 2>/dev/null)
CTRL_JOFF=$(EIGS_JIT_OFF=1 EIGS_REPLAY="$TMPDIR/v.tape" "$EIGS" "$TMPDIR/p_list.eigs" 2>/dev/null)
if [ "$CTRL" = "$GOOD" ] && [ "$CTRL_JOFF" = "$GOOD" ]; then
    ok "version control: untampered tape replays, JIT on and off"
else
    fail "version control" "rec='$GOOD' rep='$CTRL' rep_joff='$CTRL_JOFF'"
fi

refuse_case() {  # $1 label  $2 tape  $3 expected-stderr-substring
    local err rc out
    out=$(EIGS_REPLAY="$2" "$EIGS" "$TMPDIR/p_list.eigs" 2>"$TMPDIR/v.err")
    rc=$?
    err=$(cat "$TMPDIR/v.err")
    if [ "$rc" = "3" ] && [ -z "$out" ] && echo "$err" | grep -q "$3"; then
        ok "version refuse: $1 aborts with exit 3"
    else
        fail "version refuse: $1" "rc=$rc out='$out' err='$err'"
    fi
}

# Format-version mismatch.
sed '1s/^V [0-9]*/V 999/' "$TMPDIR/v.tape" > "$TMPDIR/v_fmt.tape"
refuse_case "format mismatch" "$TMPDIR/v_fmt.tape" "tape format v999"

# Runtime-version mismatch.
sed '1s/^\(V [0-9]*\) .*/\1 0.0.0-elsewhere/' "$TMPDIR/v.tape" > "$TMPDIR/v_run.tape"
refuse_case "runtime mismatch" "$TMPDIR/v_run.tape" "recorded on EigenScript 0.0.0-elsewhere"

# Headerless (pre-#411 tape shape).
sed '1d' "$TMPDIR/v.tape" > "$TMPDIR/v_none.tape"
refuse_case "missing header" "$TMPDIR/v_none.tape" "no version header"

# Empty file is not a tape.
: > "$TMPDIR/v_empty.tape"
refuse_case "empty tape" "$TMPDIR/v_empty.tape" "empty replay tape"

# Unopenable EIGS_REPLAY path (the most common operator error) is fatal too —
# a warn-and-run-live would be the same silent divergence as a bad header.
refuse_case "unopenable path" "$TMPDIR/does_not_exist.tape" "cannot open EIGS_REPLAY"

# Torn mid-stream session header (concatenated-journal corruption): a bare
# 'V' line must refuse loudly, not slip through the record filter.
# (head/tail, not `sed 2i` — BSD sed rejects the GNU one-liner form.)
{ head -1 "$TMPDIR/v.tape"; echo "V"; tail -n +2 "$TMPDIR/v.tape"; } > "$TMPDIR/v_torn.tape"
refuse_case "torn mid-stream header" "$TMPDIR/v_torn.tape" "malformed tape version header"

# A stale EIGS_REPLAY must not take down pure queries: --version/--help are
# handled before trace_init, so they succeed even with a refusable tape set.
VOUT=$(EIGS_REPLAY="$TMPDIR/v_none.tape" "$EIGS" --version 2>/dev/null); VRC=$?
if [ "$VRC" = "0" ] && [ -n "$VOUT" ]; then
    ok "stale EIGS_REPLAY: --version still works (exit 0)"
else
    fail "stale EIGS_REPLAY --version" "rc=$VRC out='$VOUT'"
fi

# ---- #471: args (argv) is a taped nondeterminism source ----
# Record the tape under one argv, then replay the SAME script under a
# DIFFERENT argv. The recorded args must win — a program that branches on
# args would otherwise silently diverge on replay (the closed-world hole).
cat > "$TMPDIR/p_args.eigs" <<'EOF'
print of (args of null)
EOF

TAPE_A="$TMPDIR/args.tape"
REC_A=$(EIGS_TRACE="$TAPE_A" "$EIGS" "$TMPDIR/p_args.eigs" A B 2>&1)
# Live (no replay) under the mutated argv — proves the tape actually overrides.
LIVE_A=$(EIGS_TRACE=/dev/null "$EIGS" "$TMPDIR/p_args.eigs" X Y Z 2>&1)
REP_A=$(EIGS_REPLAY="$TAPE_A" "$EIGS" "$TMPDIR/p_args.eigs" X Y Z 2>&1)

if [ "$REC_A" = '["A", "B"]' ] && [ "$REP_A" = '["A", "B"]' ] && [ "$LIVE_A" = '["X", "Y", "Z"]' ]; then
    ok "args replay: recorded argv wins under EIGS_REPLAY with a mutated argv"
else
    fail "args replay" "rec='$REC_A' live='$LIVE_A' rep='$REP_A'"
fi

echo
echo "REPLAY: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] && exit 0 || exit 1
