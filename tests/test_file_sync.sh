#!/bin/bash
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
EIGS=${EIGS:-"$ROOT/src/eigenscript"}
HOOK_EIGS=${HOOK_EIGS:-"$ROOT/build/test/eigenscript_fsync_hooks"}
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
EIGS_TRACE="$T/tape" "$HOOK_EIGS" "$T/live.eigs" > "$T/record.out" 2> "$T/record.err"
if [ "$?" -eq 0 ] &&
   [ "$(grep -c '^EIGS_TEST_FSYNC: file_sync$' "$T/record.err" || true)" -eq 1 ] &&
   [ "$(grep -c '^EIGS_TEST_FSYNC: dir_sync$' "$T/record.err" || true)" -eq 1 ]; then
    pass "file_sync and dir_sync reach the fsync counting hook"
else
    fail "expected two fsync hook calls"
    cat "$T/record.err"
fi
rm -f "$T/final"
EIGS_REPLAY="$T/tape" "$HOOK_EIGS" "$T/live.eigs" > "$T/replay.out" 2> "$T/replay.err"
if [ "$?" -eq 0 ] && cmp -s "$T/record.out" "$T/replay.out" &&
   ! grep -q '^EIGS_TEST_FSYNC:' "$T/replay.err" && [ ! -e "$T/final" ]; then
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

# A blocking open used to hang forever when a reader-less FIFO was supplied.
# Reuse the portable background/poll/kill timeout pattern from
# test_file_exists_fifo.sh (macOS runners do not necessarily have timeout(1)).
mkfifo "$T/pipe" || { fail "mkfifo unavailable"; exit "$fail"; }
cat > "$T/fifo.eigs" <<EOF2
try:
    file_sync of "$T/pipe"
catch e:
    print of e.kind
try:
    dir_sync of "$T/pipe"
catch e:
    print of e.kind
EOF2
"$EIGS" "$T/fifo.eigs" > "$T/fifo.out" 2>&1 &
pid=$!
rc=
i=0
while [ "$i" -lt 50 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; rc=$?; break; fi
    sleep 0.1
    i=$((i + 1))
done
if [ -z "$rc" ]; then
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    fail "file_sync or dir_sync blocked on a reader-less FIFO"
elif [ "$rc" -eq 0 ] && [ "$(grep -c '^io$' "$T/fifo.out" || true)" -eq 2 ]; then
    pass "file_sync and dir_sync promptly reject a FIFO with standard io errors"
else
    fail "FIFO sync rejection: rc=$rc output=$(tr '\n' '|' < "$T/fifo.out")"
fi

exit "$fail"
