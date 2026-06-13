#!/usr/bin/env bash
# Phase 0c: `import name` resolves through `eigs_modules/<name>/<name>.eigs`
# walking up from the importing file's directory to the project root
# (the directory containing eigs.json). Layout for the positive case:
#
#   <tmp>/
#     eigs.json                       (project-root marker)
#     eigs_modules/greeting/greeting.eigs
#     sub/deep/app.eigs               (main; imports greeting)
#
# Without the eigs_modules step, `import greeting` would scan cwd,
# sub/deep/, sub/deep/.., the exe-relative paths, and $HOME stdlib —
# never reaching <tmp>/eigs_modules — and fail. With it, the walk
# climbs from sub/deep/ to <tmp>/ and binds greeting.
#
# Second check: with eigs.json at <tmp>/sub/, the walk must stop there
# and NOT see <tmp>/eigs_modules — so the import fails. This is the
# "project root halts the walk" rule from PACKAGE_DESIGN.md.
set -euo pipefail

EIGS="${EIGENSCRIPT:-./eigenscript}"
TMP=$(mktemp -d)
trap "rm -rf '$TMP'" EXIT

# Hermetic HOME so the resolver's stdlib step can't accidentally
# satisfy `import greeting` from a real user install.
export HOME="$TMP/empty_home"
mkdir -p "$HOME"

# ----- positive case: eigs_modules at project root -----
mkdir -p "$TMP/eigs_modules/greeting" "$TMP/sub/deep"
cat > "$TMP/eigs.json" <<'EOF'
{"name": "app", "version": "0.0.0"}
EOF
cat > "$TMP/eigs_modules/greeting/greeting.eigs" <<'EOF'
hello is "world"
EOF
cat > "$TMP/sub/deep/app.eigs" <<'EOF'
import greeting
print of greeting.hello
EOF

OUT=$("$EIGS" "$TMP/sub/deep/app.eigs" 2>&1) || {
    echo "  FAIL: eigs_modules walk-up (rc=$?)"
    echo "$OUT" | head -5
    exit 1
}
if [ "$OUT" != "world" ]; then
    echo "  FAIL: eigs_modules walk-up: got '$OUT', expected 'world'"
    exit 1
fi
echo "  PASS: eigs_modules walk-up finds project-root package"

# ----- negative case: project root halts the walk -----
# Move the package out to <tmp>/outer/eigs_modules/ and put a fresh
# eigs.json marker at <tmp>/sub/ — the walk must stop at sub/ and
# never see the outer eigs_modules.
TMP2=$(mktemp -d)
trap "rm -rf '$TMP' '$TMP2'" EXIT
mkdir -p "$TMP2/sub/deep" "$TMP2/outer/eigs_modules/greeting"
cat > "$TMP2/sub/eigs.json" <<'EOF'
{"name": "inner_project"}
EOF
cat > "$TMP2/outer/eigs_modules/greeting/greeting.eigs" <<'EOF'
hello is "should-not-reach-me"
EOF
cat > "$TMP2/sub/deep/app.eigs" <<'EOF'
import greeting
print of greeting.hello
EOF

# Run in a hermetic dir + HOME so the resolver's cwd + stdlib steps
# can't satisfy the import either.
mkdir -p "$TMP2/cwd"
if OUT2=$(cd "$TMP2/cwd" && HOME="$TMP/empty_home" "$EIGS" "$TMP2/sub/deep/app.eigs" 2>&1); then
    echo "  FAIL: project root failed to halt walk (got '$OUT2')"
    exit 1
fi
echo "  PASS: eigs.json halts the walk before outer eigs_modules"
