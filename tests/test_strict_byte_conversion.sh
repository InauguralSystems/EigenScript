#!/bin/bash
# #1590: list-backed byte conversions reject nonnumeric elements by default,
# retain the exact compatibility conversion with EIGS_STRICT=0, and preserve
# str_from_bytes' terminating numeric NUL contract. Probe codec availability
# so the zlib CI suite automatically exercises the codec rows.

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="${EIGS_BIN:-$(cd "$TESTS_DIR/.." && pwd)/src/eigenscript}"
PASS=0
FAIL=0
TMP=$(mktemp /tmp/eigs_strict_bytes_XXXXXX.eigs)
trap 'rm -f "$TMP"' EXIT

byte_tmo() {
    if command -v timeout >/dev/null 2>&1; then timeout 10 "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout 10 "$@"
    else "$@"
    fi
}

run() {
    local name="$1" mode="$2" expected_rc="$3" expected="$4" program="$5"
    printf '%s\n' "$program" > "$TMP"
    local out rc
    if [ "$mode" = unset ]; then
        out=$(byte_tmo env -u EIGS_STRICT "$EIGS" "$TMP" 2>&1); rc=$?
    else
        out=$(EIGS_STRICT="$mode" byte_tmo "$EIGS" "$TMP" 2>&1); rc=$?
    fi
    if [ "$rc" = "$expected_rc" ] && printf '%s' "$out" | grep -qF -- "$expected" \
       && [[ "$out" != *"Sanitizer:"* && "$out" != *"runtime error:"* ]]; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name (rc=$rc out='$out')"
        FAIL=$((FAIL + 1))
    fi
}

run "default rejects a mixed byte list" unset 1 \
    "str_from_bytes: expected numeric byte values" \
    'print of (str_from_bytes of [65, "x", 66])'
run "explicit strict rejects after ordinary bytes" 1 1 \
    "str_from_bytes: expected numeric byte values" \
    'print of (str_from_bytes of [65, 66, "x"])'
run "strict byte-list error is catchable and typed" 1 0 "type_mismatch" \
    'try:
    print of (str_from_bytes of [65, "x"])
catch err:
    print of err.kind'
run "compatibility mode keeps the legacy truncation" 0 0 "[A]" \
    'print of f"[{str_from_bytes of [65, "x", 66]}]"'
run "numeric-only bytes remain accepted" unset 0 "[AB]" \
    'print of f"[{str_from_bytes of [65, 66]}]"'
run "empty byte list remains accepted" 1 0 "[]" \
    'print of f"[{str_from_bytes of []}]"'
run "genuine numeric NUL still terminates" unset 0 "[A]" \
    'print of f"[{str_from_bytes of [65, 0, 66]}]"'
run "elements after numeric NUL are not inspected" 1 0 "[A]" \
    'print of f"[{str_from_bytes of [65, 0, "not converted"]}]"'
run "strict non-list diagnostic is unchanged" 1 1 \
    "str_from_bytes: expected a list or buffer of byte values" \
    'print of (str_from_bytes of 42)'
run "compatibility non-list stand-in is unchanged" 0 0 "[]" \
    'print of f"[{str_from_bytes of 42}]"'

run "numeric buffer conversion remains accepted" unset 0 "[AB]" \
    'print of f"[{str_from_bytes of (buf_from_list of [65, 66])}]"'
run "numeric buffer NUL remains a terminator" 1 0 "[A]" \
    'print of f"[{str_from_bytes of (buf_from_list of [65, 0, 66])}]"'

# Use a tiny valid operation: unexpected failure is a test failure, not a skip.
printf '%s\n' 'try:
    payload is deflate of ([])
    print of "CODECS_ENABLED"
catch err:
    print of err.message' > "$TMP"
codec_probe=$(byte_tmo env -u EIGS_STRICT "$EIGS" "$TMP" 2>&1); codec_rc=$?
if [ "$codec_rc" != 0 ]; then
    echo "  FAIL: codec availability probe (rc=$codec_rc out='$codec_probe')"
    FAIL=$((FAIL + 1))
elif [ "$codec_probe" = "CODECS_ENABLED" ]; then
    run "raw codec round-trip accepts tiny valid bytes" unset 0 "[65, 0, 66]" \
        'print of (inflate of (deflate of [65, 0, 66]))'
    run "wrapped codec round-trip accepts empty input" 1 0 "[]" \
        'print of (zlib_inflate of (zlib_deflate of []))'
    run "default codec conversion rejects nonnumeric byte" unset 1 \
        "deflate: expected numeric byte values" \
        'print of (deflate of [65, "x", 66])'
    run "explicit strict wrapped conversion rejects nonnumeric byte" 1 1 \
        "zlib_deflate: expected numeric byte values" \
        'print of (zlib_deflate of [65, "x", 66])'
    run "compatibility codec conversion preserves numeric-or-zero" 0 0 "[65, 0, 66]" \
        'print of (inflate of (deflate of [65, "x", 66]))'
    run "raw inflate rejects a nonnumeric byte" unset 1 \
        "inflate: expected numeric byte values" \
        'print of (inflate of [3, "x"])'
    run "wrapped inflate rejects a nonnumeric byte" 1 1 \
        "zlib_inflate: expected numeric byte values" \
        'print of (zlib_inflate of [120, 156, 3, "x", 0, 0, 0, 1])'
    run "raw inflate compatibility retains zero conversion" 0 0 "[]" \
        'print of (inflate of [3, "x"])'
    run "wrapped inflate compatibility retains zero conversion" 0 0 "[]" \
        'print of (zlib_inflate of [120, 156, 3, "x", 0, 0, 0, 1])'
    run "raw codecs retain numeric buffer input" 1 0 "[65, 0, 66]" \
        'print of (inflate of (buf_from_list of (deflate of (buf_from_list of [65, 0, 66]))))'
    run "wrapped codecs retain numeric buffer input" unset 0 "[65, 0, 66]" \
        'print of (zlib_inflate of (buf_from_list of (zlib_deflate of (buf_from_list of [65, 0, 66]))))'
elif [[ "$codec_probe" != "deflate: compiled without zlib support"* ]]; then
    echo "  FAIL: unexpected codec availability response '$codec_probe'"
    FAIL=$((FAIL + 1))
fi

echo "STRICT_BYTE_CONVERSION: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
