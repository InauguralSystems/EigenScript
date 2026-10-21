#!/bin/bash
# #1668: mutating file builtins run live on replay, but expose their taped result.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$TESTS_DIR/.." && pwd)/src/eigenscript"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs_file_mutation_replay.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

mkdir "$TMP/live"
cat > "$TMP/case.eigs" <<EOF
print of (write_text of ["$TMP/live/text", "hello"])
print of (write_bytes of ["$TMP/live/bytes", [65, 0, 66]])
print of (rename of ["$TMP/live/text", "$TMP/live/renamed"])
print of (remove_file of "$TMP/live/renamed")

try:
    write_text of ["$TMP/block/text", "x"]
catch e:
    print of e.message
try:
    write_bytes of ["$TMP/block/bytes", [1]]
catch e:
    print of e.message
try:
    rename of ["$TMP/block/from", "$TMP/block/to"]
catch e:
    print of e.message
try:
    remove_file of "$TMP/block/remove"
catch e:
    print of e.message
EOF

EIGS_TRACE="$TMP/tape" "$BIN" "$TMP/case.eigs" > "$TMP/record.out" 2>&1
record_rc=$?

# Invert every live observation. Recorded successes now encounter a missing
# parent. Recorded ENOENT failures now encounter a regular file where their
# parent directory was, and therefore produce ENOTDIR live. Replay must still
# return/re-raise only the recorded results while performing each operation.
rm -rf "$TMP/live"
printf blocker > "$TMP/block"
EIGS_REPLAY="$TMP/tape" "$BIN" "$TMP/case.eigs" > "$TMP/replay.out" 2>&1
replay_rc=$?

if [ "$record_rc" -ne 0 ] || [ "$replay_rc" -ne 0 ]; then
    echo "  FAIL: file mutation replay (record rc=$record_rc, replay rc=$replay_rc)"
    cat "$TMP/record.out" "$TMP/replay.out"
    exit 1
fi
if ! cmp -s "$TMP/record.out" "$TMP/replay.out"; then
    echo "  FAIL: file mutation replay (stdout/stderr differ)"
    diff -u "$TMP/record.out" "$TMP/replay.out" || true
    exit 1
fi

cat "$TMP/record.out"
echo "  PASS: file mutation results replay byte-identical after every live outcome changed"
