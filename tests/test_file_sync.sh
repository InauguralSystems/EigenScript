#!/bin/bash
set -u
EIGS=${EIGS:-"$(cd "$(dirname "$0")/.." && pwd)/src/eigenscript"}
T=$(mktemp -d "${TMPDIR:-/tmp}/eigs-file-sync.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fail=$((fail + 1)); }

cat > "$T/live.eigs" <<EOF2
print of (write_text of ["$T/tmp", "durable"])
print of (file_sync of "$T/tmp")
print of (rename of ["$T/tmp", "$T/final"])
print of (dir_sync of "$T")
EOF2
: > "$T/calls"
EIGS_TEST_FSYNC_LOG="$T/calls" EIGS_TRACE="$T/tape" "$EIGS" "$T/live.eigs" > "$T/record.out" 2> "$T/record.err"
if [ "$?" -eq 0 ] && [ "$(wc -l < "$T/calls" | tr -d ' ')" -eq 2 ]; then
    pass "file_sync and dir_sync reach the fsync counting hook"
else
    fail "expected two fsync hook calls"
    cat "$T/record.err"
fi
rm -f "$T/final"
EIGS_TEST_FSYNC_LOG="$T/calls" EIGS_REPLAY="$T/tape" "$EIGS" "$T/live.eigs" > "$T/replay.out" 2> "$T/replay.err"
if [ "$?" -eq 0 ] && cmp -s "$T/record.out" "$T/replay.out" &&
   [ "$(wc -l < "$T/calls" | tr -d ' ')" -eq 2 ] && [ ! -e "$T/final" ]; then
    pass "replay returns recorded sync results without syncing or mutating"
else
    fail "replay performed a live effect or changed its result"
fi

expect_io() {
    name=$1 source=$2 needle=$3
    cat > "$T/error.eigs" <<EOF2
try:
    $source
catch e:
    print of f"{e.kind}|{e.message}"
EOF2
    if "$EIGS" "$T/error.eigs" > "$T/out" 2>&1 &&
       grep -q '^io|' "$T/out" && grep -q "$needle" "$T/out"; then
        pass "$name raises standard io error"
    else
        fail "$name standard io diagnostic"
        cat "$T/out"
    fi
}
expect_io "missing file" "file_sync of \"$T/missing\"" "missing"
mkdir "$T/a-directory"
expect_io "directory passed as file" "file_sync of \"$T/a-directory\"" "Is a directory"

exit "$fail"
