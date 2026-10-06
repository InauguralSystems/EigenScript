#!/usr/bin/env bash
set -u

EIGENSCRIPT=${EIGENSCRIPT:-./eigenscript}
tmp=${TMPDIR:-/tmp}/eigs-tensor-limit-$$
mkdir -p "$tmp" || exit 1
trap 'rm -rf "$tmp"' EXIT

# A valid header above the aggregate cap exercises tensor_load's own rejection
# rather than a writer's guard.  No payload is needed: the header must lose
# before allocation or data reads.
python3 - "$tmp/over.tensor" <<'PY'
import struct
import sys
with open(sys.argv[1], "wb") as f:
    f.write(struct.pack("=4I", 1, 1, 10_000_001, 0))
PY

cat >"$tmp/test.eigs" <<EOF
load_file of "lib/test.eigs"

# The old reader's per-dimension 1,000,000 cap rejected this file with null.
regression is zeros of 1000001
assert_eq of [tensor_save of [regression, "$tmp/regression.tensor"], true, "save old-over-cap tensor"]
regression_back is tensor_load of "$tmp/regression.tensor"
assert_eq of [len of regression_back, 1000001, "load dimension above old cap"]

# Pin writer/reader symmetry at the shared construction/file limit.
at_limit is zeros of 10000000
assert_eq of [tensor_save of [at_limit, "$tmp/limit.tensor"], true, "save tensor at limit"]
limit_back is tensor_load of "$tmp/limit.tensor"
assert_eq of [len of limit_back, 10000000, "load tensor at limit"]
assert_eq of [limit_back[9999999], 0, "last element survives limit round trip"]

caught is null
try:
    tensor_load of "$tmp/over.tensor"
catch e:
    caught is e
assert_eq of [caught.kind, "limit", "over-cap load is catchable"]
assert of [contains of [caught.message, "$tmp/over.tensor"], "over-cap error names path"]
assert of [contains of [caught.message, "columns=10000001"], "over-cap error names dimension"]
assert of [contains of [caught.message, "10000000-element cap"], "over-cap error names cap"]

writer_caught is false
try:
    stream_open of ["$tmp/writer.tensor", 10000001]
catch e:
    writer_caught is (e.kind == "limit")
assert_eq of [writer_caught, true, "stream writer refuses above reader cap"]

test_summary of null
EOF

if "$EIGENSCRIPT" "$tmp/test.eigs"; then
    echo "  PASS: tensor file limit program completed all checks"
else
    rc=$?
    echo "  FAIL: tensor file limit program exited $rc"
    exit "$rc"
fi

# Record only the new cap decision; successful tensor payloads stay live.
# Every replay includes a changed environment input after tensor_load so a
# skipped or double-consumed observation cannot silently shift the tape cursor.
cat >"$tmp/replay.eigs" <<EOF
caught is "none"
message is ""
try:
    tensor_load of "$tmp/over.tensor"
catch e:
    caught is e.kind
    message is e.message
print of f"{caught}|{message}"
print of (env_get of "EIGS_TENSOR_REPLAY_WITNESS")
EOF

recorded=$(EIGS_TENSOR_REPLAY_WITNESS=recorded EIGS_TRACE="$tmp/over.tape" "$EIGENSCRIPT" "$tmp/replay.eigs" 2>&1); record_rc=$?
expected=$(printf "limit|tensor_load: '%s' has columns=10000001, over the 10000000-element cap\nrecorded" "$tmp/over.tensor")
record_names=$(sed -n 's/^N [0-9][0-9]* \([^=]*\)=.*/\1/p' "$tmp/over.tape")
expected_names=$(printf 'tensor_load\nenv_get')
if [ "$record_rc" -ne 0 ] || [ "$recorded" != "$expected" ] || [ "$record_names" != "$expected_names" ]; then
    echo "  FAIL: cap recording did not produce the exact diagnostic and two ordered observations (rc=$record_rc)"
    printf '%s\n' "$recorded"
    exit 1
fi

mv "$tmp/over.tensor" "$tmp/over-original.tensor" || exit 1
replayed=$(EIGS_TENSOR_REPLAY_WITNESS=changed EIGS_REPLAY_STRICT=1 EIGS_REPLAY="$tmp/over.tape" "$EIGENSCRIPT" "$tmp/replay.eigs" 2>&1); replay_rc=$?
if [ "$replay_rc" -ne 0 ] || [ "$replayed" != "$recorded" ]; then
    echo "  FAIL: cap catch/diagnostic/alignment changed after file removal (rc=$replay_rc)"
    printf '%s\n' "$replayed"
    exit 1
fi

# Replace the absent file with an ordinary complete tensor for a second replay.
cat >"$tmp/small.eigs" <<EOF
load_file of "lib/test.eigs"
assert_eq of [tensor_save of [[4, 7, -2, 1.5], "$tmp/over.tensor"], true, "write ordinary replay fixture"]
test_summary of null
EOF
if ! "$EIGENSCRIPT" "$tmp/small.eigs"; then
    echo "  FAIL: ordinary replay fixture could not be written"
    exit 1
fi
replayed=$(EIGS_TENSOR_REPLAY_WITNESS=changed EIGS_REPLAY_STRICT=1 EIGS_REPLAY="$tmp/over.tape" "$EIGENSCRIPT" "$tmp/replay.eigs" 2>&1); replay_rc=$?
if [ "$replay_rc" -ne 0 ] || [ "$replayed" != "$recorded" ]; then
    echo "  FAIL: cap catch/diagnostic/alignment changed after file replacement (rc=$replay_rc)"
    printf '%s\n' "$replayed"
    exit 1
fi

# Immutable ordinary payloads still load normally; their null observation must
# be consumed before the following recorded environment call.
cat >"$tmp/positive.eigs" <<EOF
print of (tensor_load of "$tmp/over.tensor")
print of (env_get of "EIGS_TENSOR_REPLAY_WITNESS")
EOF
positive=$(EIGS_TENSOR_REPLAY_WITNESS=recorded EIGS_TRACE="$tmp/positive.tape" "$EIGENSCRIPT" "$tmp/positive.eigs" 2>&1); positive_rc=$?
positive_replay=$(EIGS_TENSOR_REPLAY_WITNESS=changed EIGS_REPLAY_STRICT=1 EIGS_REPLAY="$tmp/positive.tape" "$EIGENSCRIPT" "$tmp/positive.eigs" 2>&1); positive_replay_rc=$?
positive_expected=$(printf '[4, 7, -2, 1.5]\nrecorded')
positive_names=$(sed -n 's/^N [0-9][0-9]* \([^=]*\)=.*/\1/p' "$tmp/positive.tape")
if [ "$positive_rc" -ne 0 ] || [ "$positive_replay_rc" -ne 0 ] || [ "$positive" != "$positive_expected" ] || [ "$positive_replay" != "$positive" ] || [ "$positive_names" != "$expected_names" ]; then
    echo "  FAIL: ordinary tensor payload/alignment changed (record=$positive_rc replay=$positive_replay_rc)"
    printf '%s\n' "$positive" "$positive_replay"
    exit 1
fi

# Pin a non-cap decision too. A later over-cap file retains the historical null
# stand-in, rather than introducing a catch that the recording did not take.
noncap=$(EIGS_TENSOR_REPLAY_WITNESS=recorded EIGS_TRACE="$tmp/noncap.tape" "$EIGENSCRIPT" "$tmp/replay.eigs" 2>&1); noncap_rc=$?
noncap_expected=$(printf 'none|\nrecorded')
noncap_names=$(sed -n 's/^N [0-9][0-9]* \([^=]*\)=.*/\1/p' "$tmp/noncap.tape")
mv "$tmp/over-original.tensor" "$tmp/over.tensor" || exit 1
noncap_replay=$(EIGS_TENSOR_REPLAY_WITNESS=changed EIGS_REPLAY_STRICT=1 EIGS_REPLAY="$tmp/noncap.tape" "$EIGENSCRIPT" "$tmp/replay.eigs" 2>&1); noncap_replay_rc=$?
if [ "$noncap_rc" -ne 0 ] || [ "$noncap_replay_rc" -ne 0 ] || [ "$noncap" != "$noncap_expected" ] || [ "$noncap_replay" != "$noncap" ] || [ "$noncap_names" != "$expected_names" ]; then
    echo "  FAIL: recorded non-cap decision introduced a cap catch (record=$noncap_rc replay=$noncap_replay_rc)"
    printf '%s\n' "$noncap" "$noncap_replay"
    exit 1
fi

echo "  PASS: cap decisions, exact diagnostics, and following observations replay after tensor file changes"
