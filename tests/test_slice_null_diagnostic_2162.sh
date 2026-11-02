#!/usr/bin/env bash
echo "PLAN: 3"
set -eu

EIGS=${EIGS:-${EIGENSCRIPT:-$(cd "$(dirname "$0")/.." && pwd)/src/eigenscript}}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/null-slice.eigs" <<'EOF'
a is null
print of (sum of a[0:2])
EOF

if "$EIGS" "$TMP/null-slice.eigs" >"$TMP/out" 2>"$TMP/err"; then
    echo "FAIL: slicing null unexpectedly succeeded"
    exit 1
fi

if grep -F "cannot slice null" "$TMP/err" >/dev/null; then
    echo "PASS: null slice diagnostic names null"
else
    echo "FAIL: null slice diagnostic did not name null"
    cat "$TMP/err"
    exit 1
fi

if ! grep -F "cannot slice none" "$TMP/err" >/dev/null; then
    echo "PASS: null slice diagnostic rejects none"
else
    echo "FAIL: null slice diagnostic exposed none"
    exit 1
fi

if ! grep -F "cannot slice number" "$TMP/err" >/dev/null; then
    echo "PASS: null slice diagnostic rejects number"
else
    echo "FAIL: null slice diagnostic exposed number"
    exit 1
fi
