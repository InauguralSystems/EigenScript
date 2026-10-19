#!/bin/bash
# #1668: file readers distinguish an empty file from an I/O failure and expose
# the path plus strerror reason through a catchable `io` error.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$TESTS_DIR/.." && pwd)/src/eigenscript"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs_file_errors.XXXXXX")
trap 'chmod -R u+rwX "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT
chmod 755 "$TMP"
mkdir "$TMP/a-directory"
printf 'secret' > "$TMP/no-read"
chmod 000 "$TMP/no-read"
: > "$TMP/empty"

pass=0 fail=0
run_error() {
    local builtin=$1 path=$2 reason=$3 label=$4
    cat > "$TMP/case.eigs" <<EOF
kind is "none"
message is ""
try:
    value is $builtin of "$path"
catch e:
    kind is e.kind
    message is e.message
print of f"{kind}|{message}"
EOF
    chmod 644 "$TMP/case.eigs"
    local out rc
    if [ "$(id -u)" -eq 0 ]; then
        out=$(runuser -u nobody -- "$BIN" "$TMP/case.eigs" 2>&1); rc=$?
    else
        out=$("$BIN" "$TMP/case.eigs" 2>&1); rc=$?
    fi
    if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF "io|$builtin: cannot open '$path': $reason"; then
        echo "  PASS: $builtin $label exposes path and OS reason"
        pass=$((pass + 1))
    else
        echo "  FAIL: $builtin $label (rc=$rc, output='$out')"
        fail=$((fail + 1))
    fi
}

for builtin in read_text read_bytes read_bytes_buf; do
    run_error "$builtin" "$TMP/missing" "No such file or directory" "missing file"
    run_error "$builtin" "$TMP/no-read" "Permission denied" "permission denied"
    run_error "$builtin" "$TMP/a-directory" "Is a directory" "directory"
done

cat > "$TMP/empty.eigs" <<EOF
t is read_text of "$TMP/empty"
b is read_bytes of "$TMP/empty"
bb is read_bytes_buf of "$TMP/empty"
print of f"text={t == ""} bytes={len of b == 0} buffer={buf_len of bb == 0}"
EOF
empty_out=$("$BIN" "$TMP/empty.eigs" 2>&1); empty_rc=$?
if [ "$empty_rc" -eq 0 ] && [ "$empty_out" = "text=true bytes=true buffer=true" ]; then
    echo "  PASS: empty files remain successful empty values"
    pass=$((pass + 1))
else
    echo "  FAIL: empty file values (rc=$empty_rc, output='$empty_out')"
    fail=$((fail + 1))
fi

# The trace tape is the determinism boundary: replay the recorded failure even
# after the formerly missing path becomes a readable file.
cat > "$TMP/replay.eigs" <<EOF
try:
    value is read_text of "$TMP/replay-missing"
catch e:
    print of f"{e.kind}|{e.message}"
EOF
recorded=$(EIGS_TRACE="$TMP/read.tape" "$BIN" "$TMP/replay.eigs" 2>&1); recorded_rc=$?
printf 'now present' > "$TMP/replay-missing"
replayed=$(EIGS_REPLAY="$TMP/read.tape" "$BIN" "$TMP/replay.eigs" 2>&1); replayed_rc=$?
if [ "$recorded_rc" -eq 0 ] && [ "$replayed_rc" -eq 0 ] &&
   [ "$recorded" = "$replayed" ] && printf '%s\n' "$recorded" | grep -q '^io|'; then
    echo "  PASS: recorded I/O error replays without consulting the live file"
    pass=$((pass + 1))
else
    echo "  FAIL: I/O error replay (record='$recorded', replay='$replayed')"
    fail=$((fail + 1))
fi

printf 'FILE READ ERRORS: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
