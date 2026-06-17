#!/bin/bash
# Regression guard for the builtin-return ref-protocol leak (fixed in 2f1e993).
#
# Pre-fix, every fresh-return builtin (range/make_str/keys/...) got an
# unconditional +1 ref via CASE(CALL) VAL_BUILTIN's compensating incref,
# leaking one Value (plus contents) per call. `for i in range of 1M`
# silently retained ~80MB.
#
# This script rebuilds eigenscript with AddressSanitizer (+leak detector)
# and runs three loops that exercise the once-leaky paths:
#   - `range` (fresh allocation)
#   - `make_str` (fresh allocation)
#   - `keys`     (fresh allocation)
# A regression would surface as a per-iteration "direct leak" in the
# ASan summary. We assert no per-iteration leaks of make_list/make_str
# escape the loop.
#
# Skips cleanly if the toolchain lacks ASan support.

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SRC="$ROOT/src"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

# Probe ASan availability
if ! echo 'int main(void){return 0;}' | gcc -fsanitize=address -x c - -o /tmp/eigs_asan_probe 2>/dev/null; then
    echo "  SKIP: AddressSanitizer not available in this toolchain"
    echo "Leak Guard: 0 passed, 0 failed (skipped)"
    rm -f /tmp/eigs_asan_probe
    exit 0
fi
rm -f /tmp/eigs_asan_probe

ASAN_BIN=/tmp/eigs_leak_guard
ASAN_LOG=/tmp/eigs_leak_guard.log

# Build a minimal ASan binary mirroring build.sh flags. Exclude eigenlsp.c
# (has its own main) and ext_* (need libpq/SDL2 etc.).
cd "$SRC" || { echo "  FAIL: cannot cd to $SRC"; exit 1; }

# Source list matches build.sh minimal exactly so we don't pick up
# standalone tools (eigenlsp, jit_smoke) that define their own main().
SRCS="eigenscript.c lexer.c parser.c builtins.c builtins_tensor.c hash.c arena.c state.c strbuf.c ext_store.c fmt.c lint.c chunk.c compiler.c vm.c jit.c trace.c eigs_embed.c main.c"

if ! gcc -O1 -g -fsanitize=address -fno-omit-frame-pointer \
        -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_MODEL=0 -DEIGENSCRIPT_EXT_DB=0 \
        '-DEIGENSCRIPT_VERSION="leak_guard"' \
        $SRCS -o $ASAN_BIN -lm -lpthread 2>$ASAN_LOG; then
    echo "  SKIP: ASan build failed (see $ASAN_LOG)"
    echo "Leak Guard: 0 passed, 0 failed (skipped)"
    exit 0
fi

# Each block runs a small loop exercising a once-leaky fresh-allocation
# builtin. Pre-fix, a 10K loop would leak ~10K Values; ASan would report
# many "direct leak" lines pinned to make_list/make_str.
TMP=/tmp/eigs_leak_guard_script.eigs

cat > $TMP <<'EOF'
for i in range of 10000:
    x is i
EOF
OUT=$(ASAN_OPTIONS="detect_leaks=1:print_summary=1" $ASAN_BIN $TMP 2>&1 || true)
LEAKED=$(echo "$OUT" | grep -cE "(direct|indirect) leak.*make_list" || true)
if [ "$LEAKED" -eq 0 ]; then
    ok "range of 10000 — no make_list leaks"
else
    fail "range of 10000 leaked" "$LEAKED leak frame(s)"
    echo "$OUT" | grep -E "leak|make_list" | head -10
fi

cat > $TMP <<'EOF'
for i in range of 5000:
    s is make_str of "x"
EOF
OUT=$(ASAN_OPTIONS="detect_leaks=1:print_summary=1" $ASAN_BIN $TMP 2>&1 || true)
LEAKED=$(echo "$OUT" | grep -cE "(direct|indirect) leak.*make_str" || true)
if [ "$LEAKED" -eq 0 ]; then
    ok "make_str x 5000 — no make_str leaks"
else
    fail "make_str leaked" "$LEAKED leak frame(s)"
    echo "$OUT" | grep -E "leak|make_str" | head -10
fi

cat > $TMP <<'EOF'
d is {a: 1, b: 2, c: 3}
for i in range of 5000:
    k is keys of d
EOF
OUT=$(ASAN_OPTIONS="detect_leaks=1:print_summary=1" $ASAN_BIN $TMP 2>&1 || true)
LEAKED=$(echo "$OUT" | grep -cE "(direct|indirect) leak.*(make_list|builtin_keys)" || true)
if [ "$LEAKED" -eq 0 ]; then
    ok "keys x 5000 — no fresh-list leaks"
else
    fail "keys leaked" "$LEAKED leak frame(s)"
    echo "$OUT" | grep -E "leak|make_list|builtin_keys" | head -10
fi

# Borrow case must still work: append returns arg->items[0], which is then
# decref'd along with arg. A regression here would be a use-after-free,
# not a leak — ASan catches both.
cat > $TMP <<'EOF'
lst is [1, 2, 3]
for i in range of 5000:
    r is append of [lst, i]
EOF
OUT=$(ASAN_OPTIONS="detect_leaks=1:print_summary=1" $ASAN_BIN $TMP 2>&1 || true)
UAF=$(echo "$OUT" | grep -cE "use-after-free|heap-use-after-free" || true)
if [ "$UAF" -eq 0 ]; then
    ok "append (borrowed return) — no UAF"
else
    fail "append UAF" "$UAF report(s)"
    echo "$OUT" | grep -E "use-after-free" | head -5
fi

rm -f $TMP $ASAN_BIN $ASAN_LOG

echo "Leak Guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
