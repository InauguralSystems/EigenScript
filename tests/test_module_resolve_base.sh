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

if echo "$OUT" | grep -q "PASS: module resolves its own peer"; then
    echo "  PASS: module resolves its own peer"
else
    echo "  FAIL: module resolve base"
    echo "$OUT" | head -5
    exit 1
fi
