#!/bin/bash
WERROR_FLAGS_FILE="$(dirname "$0")/../tools/werror_flags.txt"
. "$(dirname "$0")/../tools/read_werror_flags.sh" || exit 1
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
# Skips cleanly only if a compiler probe proves the toolchain lacks ASan
# support.  Source discovery and the real build are gate failures.

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SRC="$ROOT/src"
SELF="$TESTS_DIR/$(basename "$0")"
MAKE_CMD=${EIGS_LEAK_GUARD_MAKE:-make}
CC_CMD=${EIGS_LEAK_GUARD_CC:-gcc}

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

# Probe ASan availability before the planted setup-failure checks.  Otherwise
# each child takes the normal skip path when the configured compiler has no
# sanitizer support, and the parent misreports that skip as a failed plant.
if ! echo 'int main(void){return 0;}' | "$CC_CMD" $WERROR_FLAGS -fsanitize=address -x c - -o /tmp/eigs_asan_probe 2>/dev/null; then
    echo "  SKIP: AddressSanitizer not available in this toolchain"
    echo "Leak Guard: 0 passed, 0 failed (skipped)"
    rm -f /tmp/eigs_asan_probe
    exit 0
fi
rm -f /tmp/eigs_asan_probe

# Prove that the two setup failures stay failures rather than being mistaken
# for an unavailable sanitizer.  The children stop at the planted fault, so
# these checks do not duplicate the expensive leak-guard build or loops.
if [ "${EIGS_LEAK_GUARD_SELFTEST_CHILD:-0}" != 1 ]; then
    SELFTEST_DIR=$(mktemp -d "$TESTS_DIR/.leak_guard_selftest.XXXXXX") || {
        fail "could not create leak-guard plant directory"
        exit 1
    }
    trap 'rm -rf "$SELFTEST_DIR"' EXIT HUP INT TERM

    cat >"$SELFTEST_DIR/empty-make" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$SELFTEST_DIR/empty-make"
    EMPTY_OUT=$(EIGS_LEAK_GUARD_SELFTEST_CHILD=1 \
        EIGS_LEAK_GUARD_MAKE="$SELFTEST_DIR/empty-make" \
        bash "$SELF" 2>&1)
    EMPTY_RC=$?
    if [ "$EMPTY_RC" -ne 0 ] && printf '%s\n' "$EMPTY_OUT" | grep -qF "FAIL: make print-SOURCES returned an empty source list"; then
        ok "plant: empty SOURCES is a named failure"
    else
        fail "plant: empty SOURCES was not a named failure" "rc=$EMPTY_RC"
    fi

    cat >"$SELFTEST_DIR/failing-cc" <<'EOF'
#!/bin/sh
case " $* " in
    *' -x c - '*) exec gcc "$@" ;;
    *) echo "planted ASan build failure" >&2; exit 42 ;;
esac
EOF
    chmod +x "$SELFTEST_DIR/failing-cc"
    BUILD_OUT=$(EIGS_LEAK_GUARD_SELFTEST_CHILD=1 \
        EIGS_LEAK_GUARD_CC="$SELFTEST_DIR/failing-cc" \
        bash "$SELF" 2>&1)
    BUILD_RC=$?
    if [ "$BUILD_RC" -ne 0 ] && printf '%s\n' "$BUILD_OUT" | grep -qF "FAIL: ASan leak-guard build failed"; then
        ok "plant: failed ASan build is a named failure"
    else
        fail "plant: failed ASan build was not a named failure" "rc=$BUILD_RC"
    fi

    rm -rf "$SELFTEST_DIR"
    trap - EXIT HUP INT TERM
    if [ "${1:-}" = "--selftest" ]; then
        echo "Leak Guard Selftest: $PASS passed, $FAIL failed"
        [ "$FAIL" -eq 0 ]
        exit $?
    fi
fi

ASAN_BIN=/tmp/eigs_leak_guard
ASAN_LOG=/tmp/eigs_leak_guard.log

# Build a minimal ASan binary mirroring build.sh flags. Derive the source
# list from the Makefile's canonical SOURCES (via `make print-SOURCES`) rather
# than hardcoding it — a hand-copied list drifts silently every time the
# runtime grows (state.c/eigs_embed.c were missed across 0.15.0; see #223).
# SOURCES is the minimal runtime + main.c: it already excludes ext_*/model_*
# and the standalone-main tools (eigenlsp, jit_smoke) that define their own main().
cd "$ROOT" || { echo "  FAIL: cannot cd to $ROOT"; exit 1; }
SRCS=$("$MAKE_CMD" --no-print-directory -s print-SOURCES 2>/dev/null)
if [ -z "$SRCS" ]; then
    fail "make print-SOURCES returned an empty source list"
    echo "Leak Guard: $PASS passed, $FAIL failed"
    exit 1
fi
# #1340: every word is a source file. Under an inherited MAKEFLAGS=w the list
# carried make's "Entering directory" banner, the build failed and the section
# SKIPPED green below.
for w in $SRCS; do case "$w" in *.c) ;; *)
    echo "  FAIL: print-SOURCES gave a word that is not a .c file: '$w' (#1340)"
    echo "Leak Guard: 0 passed, 1 failed"
    exit 1 ;; esac; done

if ! "$CC_CMD" $WERROR_FLAGS -O1 -g -fsanitize=address -fno-omit-frame-pointer \
        -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_MODEL=0 -DEIGENSCRIPT_EXT_DB=0 \
        '-DEIGENSCRIPT_VERSION="leak_guard"' \
        $SRCS -o $ASAN_BIN -lm -lpthread 2>$ASAN_LOG; then
    fail "ASan leak-guard build failed" "see $ASAN_LOG"
    echo "Leak Guard: $PASS passed, $FAIL failed"
    exit 1
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
