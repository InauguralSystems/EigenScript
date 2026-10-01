#!/bin/bash
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d /tmp/nondet_gen_XXXXXX)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/hooks.c" <<'EOF'
/* TRACE_NONDET_RET(variable, ignored) */
TRACE_NONDET_TAKE(
    "planted_hook");
TRACE_NONDET_RECORD("planted_hook", value);
EOF
python3 "$ROOT/tools/gen_nondet_builtins.py" --output "$TMP/out.h" "$TMP/hooks.c" > "$TMP/log"
grep -q 'examined=1 hooks=2' "$TMP/log"
grep -q 'X("planted_hook")' "$TMP/out.h"
printf 'TRACE_NONDET_RET(name, value);\n' > "$TMP/bad.c"
if python3 "$ROOT/tools/gen_nondet_builtins.py" --output "$TMP/bad.h" "$TMP/bad.c" >"$TMP/bad.log" 2>&1; then
    echo "FAIL: non-literal hook was accepted"
    exit 1
fi
grep -q 'first argument must be a string literal' "$TMP/bad.log"
echo "nondet-generator: PASS planted-hook examined delta and non-literal rejection"
