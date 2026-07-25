#!/usr/bin/env bash
# Security regression: eigs.json / eigs.lock.json are DATA a repo hands us, and
# their values land in git argv positions. git parses a leading '-' as an option
# wherever it appears — including after positionals — so a lockfile
#
#     "commit": "--upload-pack=touch /tmp/pwned; git-upload-pack"
#
# turned cmd_install's `git fetch --depth 1 origin <commit>` into command
# execution. That is arbitrary code from `eigenscript --pkg install` alone,
# which directly contradicts lib/pkg.eigs's header guarantee that no code from
# a package runs during install. run_git now rejects any option-shaped argument
# that isn't one of the literal flags the file itself passes.
#
# Both checks drive the real `--pkg install` against a local git repo; the
# marker file is the oracle — if it exists, code ran.
set -euo pipefail

EIGS="${EIGENSCRIPT:-./eigenscript}"
EIGS=$(realpath "$EIGS")

if ! command -v git >/dev/null 2>&1; then
    echo "  SKIP: git not on PATH"
    exit 0
fi

TMP=$(mktemp -d)
trap "rm -rf '$TMP'" EXIT

MARKER="$TMP/PWNED"

# ---- a real local repo so the clone step succeeds and install reaches fetch ----
mkdir -p "$TMP/source"
cd "$TMP/source"
git init -q -b main
git config user.email "test@example.com"
git config user.name "Test"
echo 'greet is "hi"' > greeting.eigs
git add -A
git commit -q -m "initial"

# ---- (1) poisoned lockfile `commit` -> git fetch --upload-pack ----
mkdir -p "$TMP/proj1"
cd "$TMP/proj1"
cat > eigs.json <<EOF
{"name": "victim", "version": "0.1.0",
 "deps": {"evil/pkg": {"git": "$TMP/source", "tag": "main"}}}
EOF
cat > eigs.lock.json <<EOF
{"evil/pkg": {"git": "$TMP/source", "tag": "main",
              "commit": "--upload-pack=touch $MARKER; git-upload-pack",
              "tree": "x"}}
EOF
set +e
"$EIGS" --pkg install >/dev/null 2>&1
set -e
if [ -e "$MARKER" ]; then
    echo "  FAIL: lockfile 'commit' option injection executed a command"
    exit 1
fi
echo "  PASS: poisoned lockfile commit does not reach git as an option"

# ---- (2) poisoned manifest `git` url -> option position on clone ----
mkdir -p "$TMP/proj2"
cd "$TMP/proj2"
cat > eigs.json <<EOF
{"name": "victim", "version": "0.1.0",
 "deps": {"evil/pkg": {"git": "--upload-pack=touch $MARKER; git-upload-pack",
                       "tag": "main"}}}
EOF
set +e
"$EIGS" --pkg install >/dev/null 2>&1
set -e
if [ -e "$MARKER" ]; then
    echo "  FAIL: manifest 'git' option injection executed a command"
    exit 1
fi
echo "  PASS: option-shaped manifest git URL is refused"

# ---- (3) no over-block: an ordinary install still works ----
mkdir -p "$TMP/proj3"
cd "$TMP/proj3"
cat > eigs.json <<EOF
{"name": "victim", "version": "0.1.0",
 "deps": {"good/greeting": {"git": "file://$TMP/source", "tag": "main"}}}
EOF
set +e
OUT=$("$EIGS" --pkg install 2>&1); RC=$?
set -e
if [ "$RC" != "0" ] || [ ! -f "$TMP/proj3/eigs_modules/greeting/greeting.eigs" ]; then
    echo "  FAIL: legitimate --pkg install broke (rc=$RC)"
    echo "$OUT" | head -20
    exit 1
fi
echo "  PASS: legitimate install still clones and locks"
