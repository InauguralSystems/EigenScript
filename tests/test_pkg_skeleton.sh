#!/usr/bin/env bash
# Dispatcher-level smoke test for the `--pkg` tool: paths that don't
# touch the network — help, list on an empty dir, list reflecting a
# hand-written manifest, manifest pluralization, and bad-subcommand
# exit code. The fetch-side behaviors (add + install actually cloning)
# live in test_pkg_fetch.sh.
set -euo pipefail

# ---------------------------------------------------- how this test matches (#1122)
# NO PIPELINE DECIDES A VERDICT HERE. Mechanism, from #1120: under
# `set -o pipefail`, `echo "$s" | grep -q "$pat"` is a RACE, not a test.
# `grep -q` exits the instant it matches and closes the read end; the
# still-writing `echo` then takes SIGPIPE and exits 141; pipefail reports the
# PIPELINE as 141 — a failed match — while grep's own status was 0, MATCHED.
# The test then goes red while printing the very output it says is missing.
# `tools/strict_differential.sh --selftest` reproduces that deterministically
# on a capture larger than the pipe buffer.
#
# str_has is bash's own matcher: no fork, no pipe, no status to misread. The
# needle is QUOTED inside the pattern, so a glob character in it is a literal —
# the same promise `grep -F` made. All but one needle below is a literal with
# no BRE metacharacter, so those are the same test. The exception is the dep
# line `... v1.0.0`, whose dots WERE wildcards under grep and are literal now:
# strictly NARROWER, never wider — and wider is the only direction that could
# turn a check that can fail into one that cannot. (Verified: the test still
# passes, so the output does carry the literal.)
# The surviving `| head -N` pipelines are diagnostics inside an already-decided
# FAIL branch; they settle nothing and are not exposed.
str_has() { case "$1" in *"$2"*) return 0 ;; esac; return 1 ; }

EIGS="${EIGENSCRIPT:-./eigenscript}"
EIGS=$(realpath "$EIGS")

TMP=$(mktemp -d)
trap "rm -rf '$TMP'" EXIT

cd "$TMP"

# ---- help ----
HELP_OUT=$("$EIGS" --pkg help 2>&1)
if ! str_has "$HELP_OUT" "Subcommands:"; then
    echo "  FAIL: --pkg help missing 'Subcommands:'"
    echo "$HELP_OUT" | head -10
    exit 1
fi
echo "  PASS: --pkg help prints usage"

# ---- list on empty dir ----
LIST_EMPTY=$("$EIGS" --pkg list 2>&1)
if ! str_has "$LIST_EMPTY" "No dependencies"; then
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
if ! str_has "$LIST_ONE" "1 dependency"; then
    echo "  FAIL: --pkg list count wrong for 1 dep"
    echo "$LIST_ONE"
    exit 1
fi
if ! str_has "$LIST_ONE" "tester/vecmath  https://example/vecmath  v1.0.0"; then
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
if ! str_has "$LIST_TWO" "2 dependencies"; then
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
if ! str_has "$BARE_VERIFY" "<owner>/<name>"; then
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
