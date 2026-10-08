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

echo "STRICT_BYTE_CONVERSION: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
