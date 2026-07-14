#!/bin/bash
# #601: read_bytes_buf cap policy.
#
# The old over-cap path returned null — indistinguishable from "file
# missing", so a >10 MB asset died far downstream with a misleading
# diagnosis (DeslanStudio: "not a WAV file" for a perfectly good WAV).
# Now: over-cap RAISES a catchable `io` error naming size + cap, and
# read_bytes_buf of [path, max_bytes] is the bounded opt-in (512 MB hard
# ceiling; the 1-arg form keeps the 10 MB default). The raise survives
# record/replay: the tape carries the observed size as a VAL_NUM N
# record and the identical error is re-derived without live fs access.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$TESTS_DIR/.." && pwd)/src/eigenscript"

TMPDIR=$(mktemp -d /tmp/eigs_rbc_XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# 12 MB file: over the 10 MB default, under an opt-in 16 MB cap.
# Sparse (truncate) — reads back as zeros, allocates no real disk.
BIG="$TMPDIR/big.bin"
truncate -s $((12 * 1024 * 1024)) "$BIG"
SMALL="$TMPDIR/small.bin"
printf '\x07\x08\x09' > "$SMALL"

run_case() {
    local name="$1" prog="$2" want="$3"
    local f="$TMPDIR/case.eigs"
    printf '%s\n' "$prog" > "$f"
    local out rc
    out=$("$BIN" "$f" 2>&1); rc=$?
    if [ $rc -eq 139 ] || [ $rc -eq 134 ]; then
        echo "  FAIL: $name (crash rc=$rc)"
        echo "$out" | tail -2
    elif echo "$out" | grep -qF "$want"; then
        echo "  PASS: $name (rc=$rc)"
    else
        echo "  FAIL: $name (missing '$want', rc=$rc)"
        echo "$out" | tail -2
    fi
}

# 1. Over-cap read raises a catchable io error naming size and cap.
run_case "over-cap raises catchable io error with size+cap" \
"caught is \"none\"
msg is \"\"
try:
    b is read_bytes_buf of \"$BIG\"
catch e:
    caught is e.kind
    msg is e.message
has_size is contains of [msg, \"12582912 bytes\"]
has_cap is contains of [msg, \"10485760-byte cap\"]
print of f\"kind={caught} size={has_size} cap={has_cap}\"" \
"kind=io size=1 cap=1"

# 2. Opt-in max_bytes reads the >10 MB file fully.
run_case "opt-in [path, max_bytes] reads a >10MB file" \
"b is read_bytes_buf of [\"$BIG\", 16 * 1024 * 1024]
print of f\"len={buf_len of b} first={b[0]}\"" \
"len=12582912 first=0"

# 3. The opt-in cap is still enforced (list form, file over max_bytes).
run_case "opt-in cap still enforced" \
"caught is \"none\"
try:
    b is read_bytes_buf of [\"$BIG\", 1024 * 1024]
catch e:
    caught is e.kind
print of f\"kind={caught}\"" \
"kind=io"

# 4. 1-arg form on a small file: unchanged fast path.
run_case "1-arg small read unchanged" \
"b is read_bytes_buf of \"$SMALL\"
print of f\"{buf_len of b} {b[0]} {b[2]}\"" \
"3 7 9"

# 5. max_bytes validation: zero, over-ceiling, and non-numeric raise value.
run_case "max_bytes 0 raises value" \
"caught is \"none\"
try:
    b is read_bytes_buf of [\"$SMALL\", 0]
catch e:
    caught is e.kind
print of caught" \
"value"

run_case "max_bytes over 512MB ceiling raises value" \
"caught is \"none\"
try:
    b is read_bytes_buf of [\"$SMALL\", 1024 * 1024 * 1024]
catch e:
    caught is e.kind
print of caught" \
"value"

run_case "non-numeric max_bytes raises value" \
"caught is \"none\"
try:
    b is read_bytes_buf of [\"$SMALL\", \"lots\"]
catch e:
    caught is e.kind
print of caught" \
"value"

# 6. Missing file: the existing null contract is unchanged (NOT a raise).
run_case "missing file still returns null" \
"b is read_bytes_buf of \"$TMPDIR/nope.bin\"
print of f\"isnull={b == null}\"" \
"isnull=1"

# 7. Record/replay: the over-cap raise is re-derived from the tape with
#    the file DELETED — byte-identical output, no live fs dependence.
PROG="$TMPDIR/replay.eigs"
cat > "$PROG" <<EOF
caught is "none"
msg is ""
try:
    b is read_bytes_buf of "$BIG"
catch e:
    caught is e.kind
    msg is e.message
print of f"{caught}|{msg}"
EOF
TAPE="$TMPDIR/cap.tape"
REC=$(EIGS_TRACE="$TAPE" "$BIN" "$PROG" 2>&1)
rm -f "$BIG"
REP=$(EIGS_REPLAY="$TAPE" "$BIN" "$PROG" 2>&1)
if [ "$REC" = "$REP" ] && echo "$REC" | grep -q "^io|"; then
    echo "  PASS: over-cap raise replays byte-identical from the tape"
else
    echo "  FAIL: over-cap replay diverged"
    echo "    rec='$REC'"
    echo "    rep='$REP'"
fi
