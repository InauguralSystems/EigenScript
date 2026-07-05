#!/bin/bash
# Two-file amalgamation drop-in (#397): a fresh directory containing ONLY the
# two generated files (eigenscript_all.c + eigs_embed.h) plus a tiny host
# builds with `cc` alone — no -I, no -D, no source list — and runs eval. This
# is the Lua-grade "copy two files, call eigs_open" acceptance.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$TESTS_DIR/.."
CC="${CC:-cc}"
PASS=0; FAIL=0
pass(){ echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail(){ echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== amalgamation drop-in ==="
( cd "$ROOT" && bash tools/amalgamate.sh build ) >/dev/null 2>&1
if [ -f "$ROOT/build/eigenscript_all.c" ] && [ -f "$ROOT/build/eigs_embed.h" ]; then
    pass "amalgamate.sh emits eigenscript_all.c + eigs_embed.h"
else
    fail "amalgamation files missing"; echo "Results: $PASS passed, $((FAIL + 1)) failed"; exit 1
fi

WORK=$(mktemp -d)
cp "$ROOT/build/eigenscript_all.c" "$ROOT/build/eigs_embed.h" "$WORK/"
cat > "$WORK/host.c" <<'EOF'
#include <stdio.h>
#include "eigs_embed.h"
int main(void) {
    EigsState *st = eigs_open();
    eigs_eval_string("print of (6 * 7)\n");
    if (eigs_has_error()) { printf("ERR: %s\n", eigs_last_error_message()); return 1; }
    eigs_close(st);
    printf("host ok\n");
    return 0;
}
EOF

# `cc` ALONE from the fresh dir: no -I (headers are inlined / in cwd), no -D
# (extensions default off inside the amalgamation), no source list.
if ( cd "$WORK" && "$CC" -O2 host.c eigenscript_all.c -lm -lpthread -o host ) 2>"$WORK/cc.err"; then
    pass "fresh dir builds with cc alone (no -I, no -D, no source list)"
else
    fail "compile failed"; head -5 "$WORK/cc.err"
fi

OUT=$("$WORK/host" 2>&1 || true)
if echo "$OUT" | grep -qx "42"; then pass "embedded eval runs (6 * 7 = 42)"; else fail "eval output wrong: $OUT"; fi
if echo "$OUT" | grep -q "host ok"; then pass "host completes cleanly"; else fail "host did not complete"; fi

rm -rf "$WORK"
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
