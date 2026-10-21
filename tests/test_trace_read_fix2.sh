#!/usr/bin/env bash
set -eu

EIGS=${EIGS:-$(cd "$(dirname "$0")/.." && pwd)/build/release/eigenscript}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "PASS: $*"; }

# A hand-edited v7 metadata count must be rejected before allocation.
printf 'print of "small"\n' > "$TMP/unit.eigs"
printf 'load_file of "%s/unit.eigs"\n' "$TMP" > "$TMP/main.eigs"
EIGS_TRACE="$TMP/source.tape" "$EIGS" "$TMP/main.eigs" >/dev/null
python3 - "$TMP/source.tape" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s, n = re.subn(r'(load_file_source=\[true, .*?, )\d+(\])',
               r'\g<1>10485761\2', s, count=1)
assert n == 1
p.write_text(s)
PY
if EIGS_REPLAY="$TMP/source.tape" "$EIGS" "$TMP/main.eigs" >"$TMP/out" 2>"$TMP/err"; then
    fail "oversize edited source tape succeeded"
fi
grep -F "invalid source size 10485761 (maximum 10485760)" "$TMP/err" >/dev/null ||
    fail "oversize edited source tape lacked the bounded-size diagnostic"
ok "oversize edited source tape is refused before allocation"

# Full-fidelity N records must encode embedded NUL bytes by length, not strlen.
python3 - "$TMP/unit.eigs" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_bytes(b'print of "before"\n\0print of "after"\n')
PY
set +e
EIGS_TRACE="$TMP/nul.tape" "$EIGS" "$TMP/main.eigs" >"$TMP/nul.record" 2>"$TMP/nul.record.err"
nul_rc=$?
set -e
if grep -F '\x00print of \"after\"' "$TMP/nul.tape" >/dev/null; then
    rm "$TMP/unit.eigs"
    EIGS_REPLAY="$TMP/nul.tape" "$EIGS" "$TMP/main.eigs" >"$TMP/nul.replay" 2>"$TMP/nul.replay.err" || true
    cmp "$TMP/nul.record" "$TMP/nul.replay" >/dev/null || fail "NUL source replay output differs"
    ok "embedded-NUL source chunk and suffix replay from tape"
elif [ "$nul_rc" -ne 0 ] && grep -Ei 'NUL|length|embedded' "$TMP/nul.record.err" >/dev/null; then
    ok "embedded-NUL source is refused loudly by checked-string build"
else
    fail "source suffix after NUL was silently discarded"
fi

# tensor_load recorded only a verdict in v7, never its payload.  Replay must
# refuse rather than opening whatever file now occupies the path.
cat > "$TMP/tensor-setup.eigs" <<EOF
tensor_save of [[1, 2], "$TMP/value.tensor"]
EOF
cat > "$TMP/tensor.eigs" <<EOF
print of tensor_load of "$TMP/value.tensor"
EOF
"$EIGS" "$TMP/tensor-setup.eigs" >/dev/null
EIGS_TRACE="$TMP/tensor.tape" "$EIGS" "$TMP/tensor.eigs" >/dev/null
rm "$TMP/value.tensor"
if EIGS_REPLAY="$TMP/tensor.tape" "$EIGS" "$TMP/tensor.eigs" >"$TMP/tensor.out" 2>"$TMP/tensor.err"; then
    fail "tensor_load replay succeeded"
fi
grep -F "tensor_load: not replayable under EIGS_REPLAY" "$TMP/tensor.err" >/dev/null ||
    fail "tensor_load replay lacked refusal diagnostic"
ok "tensor_load replay refuses before payload fopen"
