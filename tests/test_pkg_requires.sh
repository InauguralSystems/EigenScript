#!/usr/bin/env bash
set -euo pipefail
EIGS=$(realpath "${EIGENSCRIPT:-./eigenscript}")
TMP=$(mktemp -d)
trap "rm -rf '$TMP'" EXIT
mkdir -p "$TMP/source"; cd "$TMP/source"
git init -q -b main
git config user.email test@example.com; git config user.name Test
printf '%s\n' '{"name":"needshttp","version":"1.0.0","deps":{},"requires":["http"]}' > eigs.json
printf '%s\n' 'loaded is "PACKAGE_SOURCE_RAN"' > needshttp.eigs
git add -A; git commit -qm initial; git tag v1
mkdir -p "$TMP/project"; cd "$TMP/project"
printf '{"name":"consumer","version":"1.0.0","deps":{"fixture/needshttp":{"git":"file://%s","tag":"v1"}}}\n' "$TMP/source" > eigs.json
"$EIGS" --pkg add fixture/needshttp "file://$TMP/source" v1 >/dev/null
HAS_HTTP=$("$EIGS" --api --json | python3 -c 'import json,sys; print(int("http" in json.load(sys.stdin)["available_variants"]))')
if [ "$HAS_HTTP" = 1 ]; then
    "$EIGS" --pkg install >/dev/null
    "$EIGS" --pkg verify >/dev/null
    printf '%s\n' 'import needshttp' 'print of needshttp.loaded' > app.eigs
    [ "$("$EIGS" app.eigs)" = PACKAGE_SOURCE_RAN ]
    echo "  PASS: running-binary probe reports http and install accepts it"
    echo "  PASS: verify accepts a requirement supplied by this binary"
    echo "  PASS: import accepts a requirement supplied by this binary"
else
    set +e
    INSTALL_OUT=$("$EIGS" --pkg install 2>&1); INSTALL_RC=$?
    VERIFY_OUT=$("$EIGS" --pkg verify 2>&1); VERIFY_RC=$?
    printf '%s\n' 'import needshttp' 'print of needshttp.loaded' > app.eigs
    IMPORT_OUT=$("$EIGS" app.eigs 2>&1); IMPORT_RC=$?
    set -e
    case "$INSTALL_OUT" in *"fixture/needshttp requires variant http (run make http)"*) ;; *) echo "$INSTALL_OUT"; exit 1 ;; esac
    case "$VERIFY_OUT" in *"fixture/needshttp requires variant http (run make http)"*) ;; *) echo "$VERIFY_OUT"; exit 1 ;; esac
    case "$IMPORT_OUT" in *"package needshttp requires the http variant; this binary was built without it (run make http)"*) ;; *) echo "$IMPORT_OUT"; exit 1 ;; esac
    [ "$INSTALL_RC" -ne 0 ] && [ "$VERIFY_RC" -ne 0 ] && [ "$IMPORT_RC" -ne 0 ]
    case "$IMPORT_OUT" in *PACKAGE_SOURCE_RAN*|*"undefined variable"*) echo "$IMPORT_OUT"; exit 1 ;; esac
    echo "  PASS: install rejects unmet http requirement with make target"
    echo "  PASS: verify rejects unmet http requirement with make target"
    echo "  PASS: import rejects before package execution with named error"
fi
