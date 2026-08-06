#!/usr/bin/env bash
# Phase 1b: --pkg add and --pkg install actually shell out to git. We
# use a local bare-ish git repo as the "remote" — file:// URLs work
# with `git clone --depth 1 --branch <tag>` and keep the test offline.
#
# Layout the test builds:
#
#   $TMP/source/         a git repo with greeting.eigs at v1.0.0
#   $TMP/project/        runs the --pkg commands; ends up with
#                        eigs_modules/greeting/greeting.eigs cloned
#                        from source/, plus eigs.json + eigs.lock.json
set -euo pipefail

EIGS="${EIGENSCRIPT:-./eigenscript}"
EIGS=$(realpath "$EIGS")

if ! command -v git >/dev/null 2>&1; then
    echo "  SKIP: git not on PATH"
    exit 0
fi

TMP=$(mktemp -d)
trap "rm -rf '$TMP'" EXIT

# ---- build the "remote" source repo ----
mkdir -p "$TMP/source"
cd "$TMP/source"
git init -q -b main
git config user.email "test@example.com"
git config user.name "Test"
cat > greeting.eigs <<'EOF'
greet is "hello from greeting"
EOF
cat > eigs.json <<'EOF'
{"name": "greeting", "version": "1.0.0", "deps": {}}
EOF
git add -A
git commit -q -m "initial"
git tag v1.0.0
SOURCE_URL="file://$TMP/source"

# ---- bare names are rejected (namespace claim) ----
mkdir -p "$TMP/project"
cd "$TMP/project"
if "$EIGS" --pkg add greeting "$SOURCE_URL" v1.0.0 >/dev/null 2>&1; then
    echo "  FAIL: --pkg add should reject bare name 'greeting'"
    exit 1
fi
BARE_ERR=$("$EIGS" --pkg add greeting "$SOURCE_URL" v1.0.0 2>&1 || true)
if ! echo "$BARE_ERR" | grep -q "<owner>/<name>"; then
    echo "  FAIL: bare-name rejection should mention <owner>/<name>"
    echo "$BARE_ERR"
    exit 1
fi
if [ -f eigs.json ]; then
    echo "  FAIL: rejected --pkg add should not write eigs.json"
    exit 1
fi
echo "  PASS: --pkg add rejects bare names"

# ---- add: clone, write manifest + lockfile ----
ADD_OUT=$("$EIGS" --pkg add tester/greeting "$SOURCE_URL" v1.0.0 2>&1)
if [ ! -f eigs.json ]; then
    echo "  FAIL: --pkg add did not write eigs.json"
    echo "$ADD_OUT"
    exit 1
fi
if [ ! -f eigs.lock.json ]; then
    echo "  FAIL: --pkg add did not write eigs.lock.json"
    echo "$ADD_OUT"
    exit 1
fi
if [ ! -f eigs_modules/greeting/greeting.eigs ]; then
    echo "  FAIL: --pkg add did not clone greeting.eigs into eigs_modules"
    echo "$ADD_OUT"
    ls -la eigs_modules/greeting/ 2>&1 || true
    exit 1
fi
LOCK_COMMIT=$(python3 -c 'import json;print(json.load(open("eigs.lock.json"))["tester/greeting"]["commit"])')
ACTUAL_COMMIT=$(git -C eigs_modules/greeting rev-parse HEAD)
if [ "$LOCK_COMMIT" != "$ACTUAL_COMMIT" ]; then
    echo "  FAIL: lock commit '$LOCK_COMMIT' != actual HEAD '$ACTUAL_COMMIT'"
    exit 1
fi
echo "  PASS: --pkg add clones + writes lockfile with correct commit"

# ---- importing the cloned package works at runtime (Phase 0c hook) ----
cat > app.eigs <<'EOF'
import greeting
print of greeting.greet
EOF
APP_OUT=$("$EIGS" app.eigs 2>&1)
if [ "$APP_OUT" != "hello from greeting" ]; then
    echo "  FAIL: import greeting from eigs_modules failed: got '$APP_OUT'"
    exit 1
fi
echo "  PASS: import greeting resolves through eigs_modules"

# ---- install: wipe eigs_modules, then reproduce from lockfile ----
rm -rf eigs_modules
INSTALL_OUT=$("$EIGS" --pkg install 2>&1)
if [ ! -f eigs_modules/greeting/greeting.eigs ]; then
    echo "  FAIL: --pkg install did not reproduce eigs_modules/greeting"
    echo "$INSTALL_OUT"
    exit 1
fi
REINSTALLED_COMMIT=$(git -C eigs_modules/greeting rev-parse HEAD)
if [ "$REINSTALLED_COMMIT" != "$LOCK_COMMIT" ]; then
    echo "  FAIL: reinstalled commit '$REINSTALLED_COMMIT' != locked '$LOCK_COMMIT'"
    exit 1
fi
echo "  PASS: --pkg install reproduces eigs_modules at the locked commit"

# ---- install in an empty project = no-op (no deps to fetch) ----
mkdir -p "$TMP/empty"
cd "$TMP/empty"
EMPTY_OUT=$("$EIGS" --pkg install 2>&1)
if ! echo "$EMPTY_OUT" | grep -q "No dependencies"; then
    echo "  FAIL: install on empty project should say 'No dependencies'"
    echo "$EMPTY_OUT"
    exit 1
fi
echo "  PASS: --pkg install with no deps is a no-op"

# ---- install survives a tag move (lock pins commit, not tag) ----
cd "$TMP/source"
# Move v1.0.0 to a new commit — simulate a force-pushed tag.
cat > greeting.eigs <<'EOF'
greet is "TAMPERED CONTENT"
EOF
git add -A
git commit -q -m "tampered"
git tag -f v1.0.0

cd "$TMP/project"
rm -rf eigs_modules
INSTALL_OUT2=$("$EIGS" --pkg install 2>&1)
APP_OUT2=$("$EIGS" app.eigs 2>&1)
if [ "$APP_OUT2" != "hello from greeting" ]; then
    echo "  FAIL: locked commit should win over moved tag — got '$APP_OUT2'"
    echo "$INSTALL_OUT2"
    exit 1
fi
echo "  PASS: lockfile wins over a moved tag"

# ---- #879: a remote whose default branch is NOT "main" ----
# `--pkg add` hardcoded `tag is "main"`, so it ran
# `git clone --branch main` and failed outright on master/trunk/develop —
# and it PERSISTED the fabricated {"tag": "main"} into eigs.json BEFORE
# attempting the clone, leaving a project `--pkg install` could never
# recover. PACKAGE_SPEC.md:60 says "default branch if omitted".
mkdir -p "$TMP/msource"
cd "$TMP/msource"
git init -q -b master
git config user.email "test@example.com"
git config user.name "Test"
cat > mylib.eigs <<'EOF'
mylib_greet is "hello from a master-branch repo"
EOF
git add -A
git commit -q -m "init on master"

mkdir -p "$TMP/mproject"
cd "$TMP/mproject"
ADD_M=$("$EIGS" --pkg add alice/mylib "file://$TMP/msource" 2>&1) || {
    echo "  FAIL: --pkg add should work on a master-branch remote"
    echo "$ADD_M"
    exit 1
}
echo "  PASS: --pkg add resolves a non-main default branch"

# The manifest must NOT carry a fabricated tag — an omitted tag stays omitted,
# which is what makes the project recoverable.
if grep -q '"tag"' eigs.json; then
    echo "  FAIL: eigs.json must not record a guessed tag"
    cat eigs.json
    exit 1
fi
echo "  PASS: an omitted tag is recorded as omitted, not guessed"

# The recovery path the old bug destroyed: reinstall from the manifest alone.
rm -rf eigs_modules
INSTALL_M=$("$EIGS" --pkg install 2>&1) || {
    echo "  FAIL: --pkg install must recover a dep with no tag"
    echo "$INSTALL_M"
    exit 1
}
cat > mapp.eigs <<'EOF'
import mylib
print of mylib.mylib_greet
EOF
MAPP_OUT=$("$EIGS" mapp.eigs 2>&1)
if [ "$MAPP_OUT" != "hello from a master-branch repo" ]; then
    echo "  FAIL: reinstalled master-branch dep should be usable — got '$MAPP_OUT'"
    exit 1
fi
echo "  PASS: --pkg install recovers a no-tag dep (was: unrecoverable)"

VERIFY_M=$("$EIGS" --pkg verify 2>&1) || {
    echo "  FAIL: --pkg verify should pass for a no-tag dep"
    echo "$VERIFY_M"
    exit 1
}
echo "  PASS: --pkg verify passes for a no-tag dep"

# An explicit tag is still honored, unchanged.
mkdir -p "$TMP/mproject2"
cd "$TMP/mproject2"
"$EIGS" --pkg add alice/mylib "file://$TMP/msource" master > /dev/null 2>&1
if ! grep -q '"tag": *"master"' eigs.json; then
    echo "  FAIL: an explicit tag must still be recorded"
    cat eigs.json
    exit 1
fi
echo "  PASS: an explicit tag is still recorded and used"
