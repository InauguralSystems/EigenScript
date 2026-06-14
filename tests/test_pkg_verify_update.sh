#!/usr/bin/env bash
# Phase 1c: --pkg verify (re-hash trees against lockfile) and
# --pkg update (re-resolve manifest tag → new commit, re-lock).
# Mirrors the Phase 1b harness: local file:// source repo, project
# dir running --pkg commands.
set -euo pipefail

EIGS="${EIGENSCRIPT:-./eigenscript}"
EIGS=$(realpath "$EIGS")

if ! command -v git >/dev/null 2>&1; then
    echo "  SKIP: git not on PATH"
    exit 0
fi

TMP=$(mktemp -d)
trap "rm -rf '$TMP'" EXIT

# ---- source repo at v1.0.0 ----
mkdir -p "$TMP/source"
cd "$TMP/source"
git init -q -b main
git config user.email "test@example.com"
git config user.name "Test"
cat > greeting.eigs <<'EOF'
greet is "hello from greeting v1"
EOF
cat > eigs.json <<'EOF'
{"name": "greeting", "version": "1.0.0", "deps": {}}
EOF
git add -A
git commit -q -m "v1"
git tag v1.0.0
SOURCE_URL="file://$TMP/source"

mkdir -p "$TMP/project"
cd "$TMP/project"
"$EIGS" --pkg add tester/greeting "$SOURCE_URL" v1.0.0 >/dev/null

# ---- verify on clean install passes ----
VERIFY_OUT=$("$EIGS" --pkg verify 2>&1)
if ! echo "$VERIFY_OUT" | grep -q "Verified 1 package"; then
    echo "  FAIL: verify on clean install should pass"
    echo "$VERIFY_OUT"
    exit 1
fi
echo "  PASS: --pkg verify accepts a clean install"

# ---- verify catches a tampered working tree ----
echo "TAMPERED" >> eigs_modules/greeting/greeting.eigs
if "$EIGS" --pkg verify >/dev/null 2>&1; then
    echo "  FAIL: verify should reject a tampered working tree"
    exit 1
fi
VERIFY_DIRTY=$("$EIGS" --pkg verify 2>&1 || true)
if ! echo "$VERIFY_DIRTY" | grep -q "TREE DRIFT"; then
    echo "  FAIL: verify should report 'TREE DRIFT' on tampered tree"
    echo "$VERIFY_DIRTY"
    exit 1
fi
echo "  PASS: --pkg verify catches a tampered working tree"

# ---- verify catches a missing checkout ----
rm -rf eigs_modules/greeting
if "$EIGS" --pkg verify >/dev/null 2>&1; then
    echo "  FAIL: verify should reject a missing checkout"
    exit 1
fi
VERIFY_GONE=$("$EIGS" --pkg verify 2>&1 || true)
if ! echo "$VERIFY_GONE" | grep -q "MISSING"; then
    echo "  FAIL: verify should report 'MISSING' on gone tree"
    echo "$VERIFY_GONE"
    exit 1
fi
echo "  PASS: --pkg verify catches a missing checkout"

# Re-install to restore good state.
"$EIGS" --pkg install >/dev/null

# ---- update with no new commit at tag is a no-op ----
UPDATE_NOOP=$("$EIGS" --pkg update 2>&1)
if ! echo "$UPDATE_NOOP" | grep -q "unchanged"; then
    echo "  FAIL: update against unchanged tag should say 'unchanged'"
    echo "$UPDATE_NOOP"
    exit 1
fi
echo "  PASS: --pkg update is a no-op when tag hasn't moved"

# ---- update picks up a new commit at the tag ----
OLD_COMMIT=$(python3 -c 'import json;print(json.load(open("eigs.lock.json"))["tester/greeting"]["commit"])')
cd "$TMP/source"
cat > greeting.eigs <<'EOF'
greet is "hello from greeting v1 (revised)"
EOF
git add -A
git commit -q -m "v1 revision"
git tag -f v1.0.0

cd "$TMP/project"
UPDATE_OUT=$("$EIGS" --pkg update 2>&1)
NEW_COMMIT=$(python3 -c 'import json;print(json.load(open("eigs.lock.json"))["tester/greeting"]["commit"])')
if [ "$NEW_COMMIT" = "$OLD_COMMIT" ]; then
    echo "  FAIL: update should advance the lockfile commit"
    echo "$UPDATE_OUT"
    exit 1
fi
if ! echo "$UPDATE_OUT" | grep -q "updated"; then
    echo "  FAIL: update should print 'updated'"
    echo "$UPDATE_OUT"
    exit 1
fi
echo "  PASS: --pkg update advances the lockfile after a tag move"

# ---- update <name> with an unknown name exits nonzero ----
if "$EIGS" --pkg update nonesuch >/dev/null 2>&1; then
    echo "  FAIL: update <unknown> should exit nonzero"
    exit 1
fi
echo "  PASS: --pkg update <unknown> exits nonzero"

# ---- verify accepts the post-update state ----
VERIFY_POST=$("$EIGS" --pkg verify 2>&1)
if ! echo "$VERIFY_POST" | grep -q "Verified 1 package"; then
    echo "  FAIL: verify should pass after update"
    echo "$VERIFY_POST"
    exit 1
fi
echo "  PASS: --pkg verify accepts the post-update state"
