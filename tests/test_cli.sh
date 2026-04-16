#!/bin/bash
# CLI and REPL integration tests for the eigenscript binary.
# Run directly or from run_all_tests.sh. Prints a summary line:
#   CLI: N passed, M failed
#
# Exit code: 0 if all pass, 1 if any fail.

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$TESTS_DIR/.." && pwd)/src"
EIGS="$SRC_DIR/eigenscript"

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

if [ ! -x "$EIGS" ]; then
    echo "  FAIL: eigenscript binary not found at $EIGS"
    echo "CLI: 0 passed, 1 failed"
    exit 1
fi

VERSION=$(cat "$TESTS_DIR/../VERSION")

# ---- --version / -v ----
OUT=$("$EIGS" --version 2>&1)
RC=$?
if [ "$RC" = "0" ] && [ "$OUT" = "$VERSION" ]; then
    ok "CLI01 --version prints VERSION and exits 0"
else
    fail "CLI01 --version" "rc=$RC out='$OUT' expected='$VERSION'"
fi

OUT=$("$EIGS" -v 2>&1)
RC=$?
if [ "$RC" = "0" ] && [ "$OUT" = "$VERSION" ]; then
    ok "CLI02 -v prints VERSION and exits 0"
else
    fail "CLI02 -v" "rc=$RC out='$OUT'"
fi

# ---- Missing script file ----
OUT=$("$EIGS" /tmp/eigs_no_such_file_xyz_$$ 2>&1)
RC=$?
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "cannot read file"; then
    ok "CLI03 missing file exits 1 with diagnostic"
else
    fail "CLI03 missing file" "rc=$RC out='$OUT'"
fi

# ---- Parse-error exit code ----
TMP=$(mktemp /tmp/eigs_cli_XXXXXX.eigs)
printf 'x is @\n' > "$TMP"
OUT=$("$EIGS" "$TMP" 2>&1)
RC=$?
rm -f "$TMP"
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "parse error"; then
    ok "CLI04 parse error exits 1 with 'parse error' diagnostic"
else
    fail "CLI04 parse error" "rc=$RC out='$OUT'"
fi

# ---- Normal execution exits 0 ----
TMP=$(mktemp /tmp/eigs_cli_XXXXXX.eigs)
printf 'print of 42\n' > "$TMP"
OUT=$("$EIGS" "$TMP" 2>&1)
RC=$?
rm -f "$TMP"
if [ "$RC" = "0" ] && [ "$OUT" = "42" ]; then
    ok "CLI05 successful script exits 0 and prints output"
else
    fail "CLI05 normal run" "rc=$RC out='$OUT'"
fi

# ---- Assert failure exits non-zero ----
TMP=$(mktemp /tmp/eigs_cli_XXXXXX.eigs)
printf 'assert of [0, "boom"]\n' > "$TMP"
OUT=$("$EIGS" "$TMP" 2>&1)
RC=$?
rm -f "$TMP"
if [ "$RC" != "0" ]; then
    ok "CLI06 assert failure exits non-zero (rc=$RC)"
else
    fail "CLI06 assert failure" "rc=$RC out='$OUT'"
fi

# ---- Script args forwarded (args builtin) ----
TMP=$(mktemp /tmp/eigs_cli_XXXXXX.eigs)
printf 'a is args of null\nfor i in a:\n    print of i\n' > "$TMP"
OUT=$("$EIGS" "$TMP" eigs_cli_marker_hello eigs_cli_marker_world 2>&1)
RC=$?
rm -f "$TMP"
if [ "$RC" = "0" ] \
   && echo "$OUT" | grep -q "eigs_cli_marker_hello" \
   && echo "$OUT" | grep -q "eigs_cli_marker_world"; then
    ok "CLI07 script args forwarded via 'args' builtin"
else
    fail "CLI07 args forwarding" "rc=$RC out='$OUT'"
fi

# ---- Script in subdirectory: script_dir resolution ----
SUBDIR=$(mktemp -d /tmp/eigs_cli_sub_XXXXXX)
printf 'print of "from-subdir"\n' > "$SUBDIR/hello.eigs"
OUT=$("$EIGS" "$SUBDIR/hello.eigs" 2>&1)
RC=$?
rm -rf "$SUBDIR"
if [ "$RC" = "0" ] && [ "$OUT" = "from-subdir" ]; then
    ok "CLI08 script in subdir runs and resolves path"
else
    fail "CLI08 subdir script" "rc=$RC out='$OUT'"
fi

# ---- REPL banner ----
OUT=$(echo "exit" | "$EIGS" 2>&1)
RC=$?
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "EigenScript $VERSION" && echo "$OUT" | grep -q "exit"; then
    ok "CLI09 REPL prints banner with version"
else
    fail "CLI09 REPL banner" "rc=$RC out='$OUT'"
fi

# ---- REPL single-line evaluation ----
# Use a unique marker string so we don't collide with echoed prompts/version.
OUT=$(printf 'print of "eigs_repl_marker_42"\nexit\n' | "$EIGS" 2>&1)
RC=$?
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "eigs_repl_marker_42"; then
    ok "CLI10 REPL evaluates print statement"
else
    fail "CLI10 REPL eval" "rc=$RC out='$OUT'"
fi

# ---- REPL 'quit' command ----
OUT=$(echo "quit" | "$EIGS" 2>&1)
RC=$?
if [ "$RC" = "0" ]; then
    ok "CLI11 REPL 'quit' command exits cleanly"
else
    fail "CLI11 REPL quit" "rc=$RC"
fi

# ---- REPL EOF (Ctrl-D) ----
OUT=$(printf '' | "$EIGS" 2>&1)
RC=$?
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "EigenScript"; then
    ok "CLI12 REPL handles EOF cleanly (exit 0)"
else
    fail "CLI12 REPL EOF" "rc=$RC"
fi

# ---- REPL multi-line block (if/else) ----
OUT=$(printf 'x is 5\nif x > 0:\n    print of "eigs_repl_marker_pos"\n\nexit\n' | "$EIGS" 2>&1)
RC=$?
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "eigs_repl_marker_pos"; then
    ok "CLI13 REPL multi-line block (if) works"
else
    fail "CLI13 REPL multi-line" "rc=$RC out='$OUT'"
fi

# ---- REPL recovers from parse error ----
OUT=$(printf 'x is @\nprint of "eigs_repl_marker_recovered"\nexit\n' | "$EIGS" 2>&1)
RC=$?
# REPL should not crash and should still execute the second line.
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "eigs_repl_marker_recovered"; then
    ok "CLI14 REPL recovers from parse error"
else
    fail "CLI14 REPL parse-error recovery" "rc=$RC out='$OUT'"
fi

# ---- Script with runtime warning still exits 0 (per EM14/EM15 convention) ----
TMP=$(mktemp /tmp/eigs_cli_XXXXXX.eigs)
printf 'x is 10 / 0\n' > "$TMP"
OUT=$("$EIGS" "$TMP" 2>&1)
RC=$?
rm -f "$TMP"
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "division by zero"; then
    ok "CLI15 division by zero warns but exits 0"
else
    fail "CLI15 div-zero warning" "rc=$RC out='$OUT'"
fi

# ---- Summary ----
echo ""
echo "CLI: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
