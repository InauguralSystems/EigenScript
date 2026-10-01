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
assert_eq of [tensor_save of [regression, "$tmp/regression.tensor"], 1, "save old-over-cap tensor"]
regression_back is tensor_load of "$tmp/regression.tensor"
assert_eq of [len of regression_back, 1000001, "load dimension above old cap"]

# Pin writer/reader symmetry at the shared construction/file limit.
at_limit is zeros of 10000000
assert_eq of [tensor_save of [at_limit, "$tmp/limit.tensor"], 1, "save tensor at limit"]
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

writer_caught is 0
try:
    stream_open of ["$tmp/writer.tensor", 10000001]
catch e:
    writer_caught is (e.kind == "limit")
assert_eq of [writer_caught, 1, "stream writer refuses above reader cap"]

test_summary of null
EOF

if "$EIGENSCRIPT" "$tmp/test.eigs"; then
    echo "  PASS: tensor file limit program completed all checks"
else
    rc=$?
    echo "  FAIL: tensor file limit program exited $rc"
    exit "$rc"
fi
