#!/usr/bin/env bash
# #2170: --pkg install builds a complete sibling tree before activation.
set -euo pipefail
EIGS="${EIGENSCRIPT:-./eigenscript}"
case "$EIGS" in /*) ;; *) EIGS="$(pwd)/$EIGS" ;; esac
REAL_GIT=$(command -v git || true)
if [ -z "$REAL_GIT" ]; then echo "SKIP: git not on PATH"; exit 0; fi
TMP=$(mktemp -d)
cleanup() { if [ -f "$TMP/wrapper.pid" ]; then kill "$(cat "$TMP/wrapper.pid")" 2>/dev/null || true; fi; rm -rf "$TMP"; }
trap cleanup EXIT HUP INT TERM
mkdir "$TMP/source"; cd "$TMP/source"
git init -q -b main; git config user.email test@example.com; git config user.name Test
printf 'value is "new"\n' > atom.eigs
printf '{"name":"atom","version":"1.0.0","deps":{}}\n' > eigs.json
git add .; git commit -qm initial
COMMIT=$(git rev-parse HEAD); TREE=$(git rev-parse 'HEAD^{tree}')
mkdir "$TMP/project"; cd "$TMP/project"
printf '{"name":"app","version":"1","deps":{"tester/atom":{"git":"file://%s","tag":"main"}}}\n' "$TMP/source" > eigs.json
printf '{"tester/atom":{"git":"file://%s","tag":"main","commit":"%s","tree":"%s"}}\n' "$TMP/source" "$COMMIT" "$TREE" > eigs.lock.json
mkdir -p eigs_modules/atom; printf 'prior\n' > eigs_modules/atom/prior.txt
cp eigs.lock.json "$TMP/lock.before"

# Clean control: without a planted interruption, install and verify succeed.
"$EIGS" --pkg install >/dev/null
"$EIGS" --pkg verify >/dev/null
printf 'PASS: uninterrupted staged install activates a verifiable tree\n'
# Mark the clean installed tree; both fault plants must preserve it.
printf 'prior\n' > eigs_modules/atom/prior.txt
git -C eigs_modules/atom add prior.txt
git -C eigs_modules/atom -c user.email=test@example.com -c user.name=Test commit -qm prior-marker
# The marker commit deliberately differs from the lock and is therefore not a
# valid control. Reset it into an ignored file instead so verify remains green.
git -C eigs_modules/atom reset -q HEAD~1
rm -f eigs_modules/atom/prior.txt
printf '.prior\n' >> eigs_modules/atom/.git/info/exclude
printf 'prior\n' > eigs_modules/atom/.prior

mkdir "$TMP/bin"
cat > "$TMP/bin/git" <<'WRAP'
#!/usr/bin/env bash
set -eu
REAL_GIT=${PKG_REAL_GIT:?}; MARK=${PKG_MARK:?}; PIDFILE=${PKG_PIDFILE:?}
printf '%s\n' "$$" > "$PIDFILE"
if [ "${1-}" = clone ]; then
    if [ "${PKG_MODE-}" = partial ]; then
        eval "target=\${$#}"
        mkdir -p "$target/.git"; printf 'partial\n' > "$target/partial"
        : > "$MARK"; sleep 30; exit 1
    fi
    "$REAL_GIT" "$@"; rc=$?; : > "$MARK"; sleep 30; exit "$rc"
fi
exec "$REAL_GIT" "$@"
WRAP
chmod +x "$TMP/bin/git"

run_interrupted() {
    mode=$1; mark="$TMP/$mode.mark"; rm -f "$mark" "$TMP/wrapper.pid"
    PATH="$TMP/bin:$PATH" PKG_REAL_GIT="$REAL_GIT" PKG_MARK="$mark" \
      PKG_PIDFILE="$TMP/wrapper.pid" PKG_MODE="$mode" "$EIGS" --pkg install >"$TMP/$mode.out" 2>&1 &
    parent=$!
    i=0; while [ ! -f "$mark" ] && kill -0 "$parent" 2>/dev/null; do sleep 0.05; i=$((i + 1)); [ "$i" -lt 400 ] || break; done
    if [ ! -f "$mark" ]; then echo "FAIL: $mode plant did not reach its interruption point"; cat "$TMP/$mode.out"; exit 1; fi
    kill -KILL "$parent" 2>/dev/null || true; wait "$parent" 2>/dev/null || true
    if [ -f "$TMP/wrapper.pid" ]; then kill "$(cat "$TMP/wrapper.pid")" 2>/dev/null || true; fi
    test -f eigs_modules/atom/.prior || { echo "FAIL: $mode exposed staged package data"; exit 1; }
    cmp -s eigs.lock.json "$TMP/lock.before" || { echo "FAIL: $mode changed the lockfile"; exit 1; }
}
run_interrupted complete
"$EIGS" --pkg verify >/dev/null 2>&1 || { echo 'FAIL: prior state did not verify after completed clone interruption'; exit 1; }
printf 'PASS: kill after clone and before activation preserves the prior project state\n'
run_interrupted partial
"$EIGS" --pkg verify >/dev/null 2>&1 || { echo 'FAIL: prior state did not verify after partial staging interruption'; exit 1; }
printf 'PASS: kill during a partial staged package write preserves the prior project state\n'
