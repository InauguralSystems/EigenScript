#!/usr/bin/env bash
set -u

EIGS=${EIGS:-${EIGENSCRIPT:-$(cd "$(dirname "$0")/.." && pwd)/src/eigenscript}}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

# Real large files, generated outside the tree.  Avoid sparse-file and GNU
# userland assumptions because this section also runs in the macOS merge queue.
python3 - "$TMP/default.bin" "$TMP/large.bin" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_bytes(b'x' * (10 * 1024 * 1024 + 1))
pathlib.Path(sys.argv[2]).write_bytes(b'y' * (15 * 1024 * 1024))
PY

for reader in read_text read_bytes read_bytes_buf; do
    cat >"$TMP/case.eigs" <<EOF
value is $reader of "$TMP/default.bin"
EOF
    if "$EIGS" "$TMP/case.eigs" >"$TMP/out" 2>"$TMP/err"
    then
        fail "$reader default accepted 10 MiB + 1 byte"
    fi
    grep -F "10485761 bytes, over the 10485760-byte cap" "$TMP/err" >/dev/null ||
        fail "$reader default refusal did not name size and cap"
    grep -F "pass $reader of [path, max_bytes]" "$TMP/err" >/dev/null ||
        fail "$reader default refusal did not name its escape"
    pass "$reader default refuses 10 MiB + 1 byte and names the escape"

    length='len of value'
    [ "$reader" = read_bytes_buf ] && length='buf_len of value'
    cat >"$TMP/read.eigs" <<EOF
value is $reader of ["$TMP/large.bin", 32 * 1024 * 1024]
print of $length
EOF
    got=$("$EIGS" "$TMP/read.eigs" 2>"$TMP/err") ||
        fail "$reader raised-cap 15 MiB read failed"
    [ "$got" = 15728640 ] || fail "$reader raised-cap read returned '$got'"
    pass "$reader reads 15 MiB with a 32 MiB cap"

    cat >"$TMP/case.eigs" <<EOF
value is $reader of ["$TMP/default.bin", 512 * 1024 * 1024 + 1]
EOF
    if "$EIGS" "$TMP/case.eigs" >"$TMP/out" 2>"$TMP/err"
    then
        fail "$reader accepted a cap above the hard ceiling"
    fi
    grep -F "1..536870912" "$TMP/err" >/dev/null ||
        fail "$reader hard-ceiling refusal lacked the ceiling"
    pass "$reader refuses a cap above the hard ceiling"
done

# Argument guards remain fail-soft outside strict mode, including when the
# path is wrapped in the new capped form.  These guards execute before the
# trace take, preserving the historical fallback records.
for reader in read_text read_bytes read_bytes_buf; do
    expected=none
    [ "$reader" = read_text ] && expected=str
    for arg in '42' '[42, 1024]' '["unused", "bad-cap"]' '["unused", -1]'; do
        cat >"$TMP/guard.eigs" <<EOF
print of type of ($reader of $arg)
EOF
        got=$(EIGS_STRICT=0 "$EIGS" "$TMP/guard.eigs" 2>"$TMP/err") ||
            fail "$reader guard for $arg raised outside strict mode"
        [ "$got" = "$expected" ] ||
            fail "$reader guard for $arg returned type '$got', expected '$expected'"
    done
    pass "$reader path and max_bytes guards retain the historical fallback"
done

cat >"$TMP/strict.eigs" <<'EOF'
value is read_text of 42
EOF
if EIGS_STRICT=1 "$EIGS" "$TMP/strict.eigs" >"$TMP/out" 2>"$TMP/err"
then
    fail "strict read_text accepted a non-string path"
fi
grep -F "read_text: expected a string path" "$TMP/err" >/dev/null ||
    fail "strict read_text did not raise its historical type guard"
pass "strict read_text raises for a non-string path"

cat >"$TMP/guard.eigs" <<'EOF'
print of read_text of 42
EOF
EIGS_STRICT=0 EIGS_TRACE="$TMP/guard.tape" "$EIGS" "$TMP/guard.eigs" >"$TMP/record" 2>"$TMP/record.err" ||
    fail "non-string guard trace recording failed"
EIGS_STRICT=0 EIGS_REPLAY="$TMP/guard.tape" "$EIGS" "$TMP/guard.eigs" >"$TMP/replay-guard" 2>"$TMP/replay-guard.err" ||
    fail "non-string guard replay failed"
cmp "$TMP/record" "$TMP/replay-guard" >/dev/null || fail "non-string guard replay diverged"
pass "a fail-soft argument guard records and replays the same fallback"

# Record a successful read under a raised cap, remove the live input, and prove
# replay retains the call's cap while serving the recorded value.
cat >"$TMP/replay.eigs" <<EOF
text is read_text of ["$TMP/large.bin", 32 * 1024 * 1024]
print of len of text
EOF
EIGS_TRACE="$TMP/read.tape" "$EIGS" "$TMP/replay.eigs" >"$TMP/record" 2>"$TMP/record.err" ||
    fail "raised-cap trace recording failed"
rm "$TMP/large.bin"
EIGS_REPLAY="$TMP/read.tape" "$EIGS" "$TMP/replay.eigs" >"$TMP/replay" 2>"$TMP/replay.err" ||
    fail "raised-cap replay failed after deleting input"
cmp "$TMP/record" "$TMP/replay" >/dev/null || fail "raised-cap replay diverged"
pass "a raised-cap read records and replays without live filesystem input"
