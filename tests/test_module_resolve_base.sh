#!/usr/bin/env bash
# Phase 0b: an `import` inside a module resolves relative to *that
# module's* directory, not the main script's. Test layout:
#
#   <tmp>/
#     main.eigs               (the main script; imports wrapper)
#     subdir/
#       wrapper.eigs          (imports peer)
#       peer.eigs             (defines `value`)
#
# Without per-file resolution, wrapper's `import peer` would search the
# main script's dir (<tmp>) and fail; with it, the search anchors at
# subdir/ and finds peer.eigs.
#
# Main resolves `wrapper` via cwd-relative (`subdir/wrapper.eigs` ↔
# `subdir/wrapper.eigs` from cwd=<tmp>) — but `import` only accepts a
# bare identifier, so we name the module `subdir_wrapper` and symlink
# the actual file in via $HOME/.local/lib/eigenscript/. Avoid polluting
# the real $HOME by overriding it.
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
# the same promise `grep -F` made. Every needle replaced below is a literal
# with no BRE metacharacter in it, so this is the same test, not a wider one —
# and WIDER is the only direction that could turn a check that can fail into
# one that cannot.
# The surviving `| head -N` pipelines are diagnostics inside an already-decided
# FAIL branch; they settle nothing and are not exposed.
str_has() { case "$1" in *"$2"*) return 0 ;; esac; return 1 ; }

EIGS="${EIGENSCRIPT:-./eigenscript}"
TMP=$(mktemp -d)
trap "rm -rf '$TMP'" EXIT

mkdir -p "$TMP/subdir" "$TMP/eigs_local/.local/lib/eigenscript"

cat > "$TMP/subdir/wrapper.eigs" <<'EOF'
import peer
exposed is peer.value + 1
EOF

cat > "$TMP/subdir/peer.eigs" <<'EOF'
value is 41
EOF

# wrapper resolves through HOME/.local/lib/eigenscript/wrapper.eigs — a
# symlink into subdir/ keeps the module's *actual* directory in subdir.
ln -s "$TMP/subdir/wrapper.eigs" "$TMP/eigs_local/.local/lib/eigenscript/wrapper.eigs"

cat > "$TMP/main.eigs" <<'EOF'
import wrapper
if wrapper.exposed == 42:
    print of "PASS: module resolves its own peer"
else:
    print of f"FAIL: expected 42, got {wrapper.exposed}"
EOF

# Override HOME so the resolver's $HOME/.local/lib/eigenscript step
# points at our temp dir; this also keeps the test hermetic.
OUT=$(HOME="$TMP/eigs_local" "$EIGS" "$TMP/main.eigs" 2>&1) || {
    echo "  FAIL: module resolve base (rc=$?)"
    echo "$OUT" | head -5
    exit 1
}

if str_has "$OUT" "PASS: module resolves its own peer"; then
    echo "  PASS: module resolves its own peer"
else
    echo "  FAIL: module resolve base"
    echo "$OUT" | head -5
    exit 1
fi
