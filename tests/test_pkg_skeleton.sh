#!/usr/bin/env bash
# Dispatcher-level smoke test for the `--pkg` tool: paths that don't
# touch the network — help, list on an empty dir, list reflecting a
# hand-written manifest, manifest pluralization, and bad-subcommand
# exit code. The fetch-side behaviors (add + install actually cloning)
# live in test_pkg_fetch.sh.
set -euo pipefail

EIGS="${EIGENSCRIPT:-./eigenscript}"
EIGS=$(realpath "$EIGS")

TMP=$(mktemp -d)
trap "rm -rf '$TMP'" EXIT

cd "$TMP"

# ---- help ----
HELP_OUT=$("$EIGS" --pkg help 2>&1)
if ! echo "$HELP_OUT" | grep -q "Subcommands:"; then
    echo "  FAIL: --pkg help missing 'Subcommands:'"
    echo "$HELP_OUT" | head -10
    exit 1
fi
echo "  PASS: --pkg help prints usage"

# ---- list on empty dir ----
LIST_EMPTY=$("$EIGS" --pkg list 2>&1)
if ! echo "$LIST_EMPTY" | grep -q "No dependencies"; then
    echo "  FAIL: --pkg list on empty dir didn't say 'No dependencies'"
    echo "$LIST_EMPTY" | head -5
    exit 1
fi
echo "  PASS: --pkg list reports no deps on a fresh dir"

# ---- list reads a hand-written manifest (no network) ----
cat > eigs.json <<'EOF'
{"name":"smoke","version":"0.0.0","deps":{"tester/vecmath":{"git":"https://example/vecmath","tag":"v1.0.0"}}}
EOF
LIST_ONE=$("$EIGS" --pkg list 2>&1)
if ! echo "$LIST_ONE" | grep -q "1 dependency"; then
    echo "  FAIL: --pkg list count wrong for 1 dep"
    echo "$LIST_ONE"
    exit 1
fi
if ! echo "$LIST_ONE" | grep -q "tester/vecmath  https://example/vecmath  v1.0.0"; then
    echo "  FAIL: --pkg list missing dep line"
    echo "$LIST_ONE"
    exit 1
fi
echo "  PASS: --pkg list reads manifest + formats dep line"

# ---- pluralization ----
cat > eigs.json <<'EOF'
{"name":"smoke","version":"0.0.0","deps":{
"tester/vecmath":{"git":"https://example/vecmath","tag":"v1.0.0"},
"tester/greeting":{"git":"https://example/greeting","tag":"v0.2.0"}}}
EOF
LIST_TWO=$("$EIGS" --pkg list 2>&1)
if ! echo "$LIST_TWO" | grep -q "2 dependencies"; then
    echo "  FAIL: --pkg list count not pluralized for 2 deps"
    echo "$LIST_TWO"
    exit 1
fi
echo "  PASS: --pkg list pluralizes the count"

# ---- install/update/verify reject a hand-written bare-name manifest ----
cat > eigs.json <<'EOF'
{"name":"smoke","version":"0.0.0","deps":{"vecmath":{"git":"https://example/vecmath","tag":"v1.0.0"}}}
EOF
if "$EIGS" --pkg verify >/dev/null 2>&1; then
    echo "  FAIL: verify should reject a bare-name manifest"
    exit 1
fi
BARE_VERIFY=$("$EIGS" --pkg verify 2>&1 || true)
if ! echo "$BARE_VERIFY" | grep -q "<owner>/<name>"; then
    echo "  FAIL: verify on bare-name manifest should mention <owner>/<name>"
    echo "$BARE_VERIFY"
    exit 1
fi
echo "  PASS: --pkg verify rejects a bare-name manifest"

# ---- bogus subcommand → nonzero exit ----
if "$EIGS" --pkg bogus_subcmd >/dev/null 2>&1; then
    echo "  FAIL: --pkg with bad subcommand should have exited nonzero"
    exit 1
fi
echo "  PASS: --pkg bogus subcommand exits nonzero"

# ---- missing subcommand → nonzero exit ----
if "$EIGS" --pkg >/dev/null 2>&1; then
    echo "  FAIL: --pkg with no subcommand should have exited nonzero"
    exit 1
fi
echo "  PASS: --pkg with no subcommand exits nonzero"
