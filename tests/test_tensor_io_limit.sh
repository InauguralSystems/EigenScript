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
at_limit is fill of [10000000, 0]
assert_eq of [tensor_save of [at_limit, "$tmp/limit.tensor"], true, "save tensor at limit"]
limit_back is tensor_load of "$tmp/limit.tensor"
assert_eq of [len of limit_back, 10000000, "load tensor at limit"]
assert_eq of [limit_back, at_limit, "tensor at limit round-trips exactly"]

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

# Format v9 records only a tensor header verdict, not payload bytes.  Replay
# consumes that verdict for tape alignment and then refuses before fopen; the
# following env_get proves the next observation remains aligned.
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
record_names=$(sed -n 's/^N [0-9][0-9]* \([^=]*\)=.*/\1/p' "$tmp/over.tape")
expected_names=$(printf 'tensor_load\nenv_get')
# Recording is unchanged by #1885: the record run still reports the exact cap
# diagnostic. Only replay refuses the payload read.
record_expected=$(printf "limit|tensor_load: '%s' has columns=10000001, over the 10000000-element cap\nrecorded" "$tmp/over.tensor")
if [ "$record_rc" -ne 0 ] || [ "$recorded" != "$record_expected" ] || [ "$record_names" != "$expected_names" ]; then
    echo "  FAIL: tensor recording did not produce the exact cap diagnostic and two ordered observations (rc=$record_rc)"
    printf '%s\n' "$recorded"
    exit 1
fi

mv "$tmp/over.tensor" "$tmp/over-original.tensor" || exit 1
replayed=$(EIGS_TENSOR_REPLAY_WITNESS=changed EIGS_REPLAY_STRICT=1 EIGS_REPLAY="$tmp/over.tape" "$EIGENSCRIPT" "$tmp/replay.eigs" 2>&1); replay_rc=$?
expected=$(printf 'io|tensor_load: not replayable under EIGS_REPLAY (file-read boundary; see docs/TRACE.md)\nrecorded')
if [ "$replay_rc" -ne 0 ] || [ "$replayed" != "$expected" ]; then
    echo "  FAIL: absent tensor was not refused with aligned following observation (rc=$replay_rc)"
    printf '%s\n' "$replayed"
    exit 1
fi

cat >"$tmp/small.eigs" <<EOF
load_file of "lib/test.eigs"
assert_eq of [tensor_save of [[4, 7, -2, 1.5], "$tmp/over.tensor"], true, "write ordinary replay fixture"]
test_summary of null
EOF
"$EIGENSCRIPT" "$tmp/small.eigs" >/dev/null || exit 1
replayed=$(EIGS_TENSOR_REPLAY_WITNESS=changed EIGS_REPLAY_STRICT=1 EIGS_REPLAY="$tmp/over.tape" "$EIGENSCRIPT" "$tmp/replay.eigs" 2>&1); replay_rc=$?
if [ "$replay_rc" -ne 0 ] || [ "$replayed" != "$expected" ]; then
    echo "  FAIL: replacement tensor escaped replay refusal (rc=$replay_rc)"
    exit 1
fi

echo "  PASS: tensor replay consumes its verdict, refuses payload reads, and preserves tape alignment"
