#!/bin/bash
# ext_gfx.c under AddressSanitizer + LeakSanitizer, over a gfx corpus (#1007).
#
# WHY THIS EXISTS. `make asan` compiles ext_gfx.c out entirely, so until
# `make asan-gfx` landed (#1018) NO sanitizer build anywhere -- local or CI --
# ever instrumented the file that every app in the fleet (DMG, dynamics, eddy,
# eigen-edit, eigen-sheet, DeslanStudio) and all 18 lib/ui modules run on.
# #1018 shipped the TARGET; it was not wired into any suite section or
# workflow, so it was a tool nobody ran. This is the gate half.
#
# WHAT THE TRIAGE FOUND, recorded here rather than in a commit message
# nobody re-reads: the corpus surfaced ONE leak, 584 bytes in 6 allocations,
# and it was OURS, not SDL's -- builtin_gfx_poll allocates its event dict
# before the switch and returned without releasing it on the two paths that
# decode nothing (a non-resize SDL_WINDOWEVENT, and any event type it has no
# case for). Fixed in ext_gfx.c. NO LeakSanitizer suppression file is
# shipped, because after that fix the corpus reports nothing to suppress --
# a suppression added "for SDL" with no leak behind it is a waiver for a
# claim nobody checked.
#
# THE POSITIVE CONTROL IS THE POINT. "No leaks reported" is also what a
# binary built WITHOUT the sanitizer says, and what a harness that greps the
# wrong stream says. So a deliberately-leaking C program is compiled with the
# same flags and judged by THE SAME predicate the corpus is judged by
# (leak_reported), and it must come back REPORTED; a matching non-leaking one
# must come back CLEAN. If either control is wrong the section fails without
# looking at the corpus at all, because a corpus verdict from a blind
# instrument is not evidence.
#
# SKIPS CLEANLY when the default toolchain has no ASan or when the binary
# has no gfx builtins. Explicit compiler selection and build failures are
# errors. libSDL2
# is NOT required: it is dlopen'd, so the corpus runs either way -- gfx_open
# answers 0 and the drawing calls no-op, which still walks every allocation
# path on the argument side. Whether SDL was present is reported, so a green
# line is not read as more coverage than the environment gave.
#
# Run by hand:  cd src && bash ../tests/test_asan_gfx.sh
set -u
TOOLCHAIN_ONLY=0
if [ "$#" -eq 0 ]; then
    :
elif [ "$#" -eq 1 ] && [ "$1" = --toolchain-only ]; then
    TOOLCHAIN_ONLY=1
else
    echo "Usage: $0 [--toolchain-only]" >&2
    exit 2
fi
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
CORPUS="$TESTS_DIR/gfx_asan_corpus"
. "$TESTS_DIR/lsan_classify.sh" || exit 1

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP: $1"; echo "ASan gfx: 0 passed, 0 failed (skipped)"; exit 0; }

# The executable startup control can hang inside sanitizer initialization.
# TERM alone cannot bound a runtime which ignores it; KILL follows after 5s.
# BEGIN gfx timeout selector (also exercised by test_gfx_timeout.py)
TMO=""
if command -v timeout >/dev/null 2>&1; then TMO="timeout -k 5 120"
elif command -v gtimeout >/dev/null 2>&1; then TMO="gtimeout -k 5 120"
else
    bad "gfx sanitizer gate requires timeout or gtimeout (install coreutils)"
    echo "ASan gfx: $PASS passed, $FAIL failed"
    exit 1
fi
# END gfx timeout selector
if ! python3 "$TESTS_DIR/test_gfx_timeout.py"; then
    bad "gfx timeout controls failed"
    echo "ASan gfx: $PASS passed, $FAIL failed"
    exit 1
fi

# The -Werror trio is spelled out on every compiler line below rather than folded
# into a variable: tools/werror_switch_check.sh reads the line, not the
# expansion, and this script is enrolled in its SCRIPT_AUDITS with a floor of
# four compile invocations.
CC="${EIGS_ASAN_GFX_CC:-gcc}"
ASAN_CFLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -g -O1"
if ! echo 'int main(void){return 0;}' | "$CC" -Werror=switch -Werror=comment -Werror=misleading-indentation $ASAN_CFLAGS -x c - -o /tmp/eigs_asan_gfx_probe 2>/tmp/eigs_asan_gfx_probe.log; then
    rm -f /tmp/eigs_asan_gfx_probe
    cat /tmp/eigs_asan_gfx_probe.log
    if [ -n "${EIGS_ASAN_GFX_CC:-}" ] || [ "$TOOLCHAIN_ONLY" -eq 1 ]; then
        bad "configured gfx sanitizer compiler cannot build the control: $CC"
        echo "ASan gfx: $PASS passed, $FAIL failed"
        exit 1
    fi
    skip "AddressSanitizer not available in this toolchain"
fi
ASAN_OPTIONS=detect_leaks=1 $TMO /tmp/eigs_asan_gfx_probe > /tmp/eigs_asan_gfx_probe.log 2>&1
START_RC=$?
if [ "$START_RC" -ne 0 ]; then
    cat /tmp/eigs_asan_gfx_probe.log
    rm -f /tmp/eigs_asan_gfx_probe
    bad "gfx sanitizer runtime cannot start with leak detection (rc=$START_RC; 120s deadline, 5s kill grace); set EIGS_ASAN_GFX_CC to a compiler with LeakSanitizer"
    echo "ASan gfx: $PASS passed, $FAIL failed"
    exit 1
fi
rm -f /tmp/eigs_asan_gfx_probe

export ASAN_OPTIONS="detect_leaks=1:abort_on_error=0"
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}"
export SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-dummy}"

# ---------------------------------------------------------------- predicate
# ONE predicate, used by the corpus rows AND by the controls. Two copies of
# this decision is how a guard goes green while the production path regresses.
LAST_OUT=""; LAST_RC=0
leak_reported() {   # <cmd...> -> 0 when a leak WAS reported
    LAST_OUT="$($TMO "$@" 2>&1)"
    LAST_RC=$?
    lsan_classify "$LAST_OUT"
}

# ------------------------------------------------------------- the controls
# The instrument is validated BEFORE any corpus verdict is believed.
CTRL_OK=1

cat > /tmp/eigs_asan_gfx_leak.c <<'CEOF'
#include <pthread.h>
#include <stdlib.h>
/* Allocate only inside a worker which is joined before process exit. The
 * main thread never holds the pointer, and the retired worker's registers
 * and stack cannot conservatively keep it reachable (notably at -O0 on
 * AArch64). Do not pass or return the allocation through pthread state. */
static int allocation_failed;
static void *allocate_in_worker(void *arg) {
    (void)arg;
    void *allocation = malloc(1234);
    if (!allocation) {
        allocation_failed = 1;
        return NULL;
    }
    *(volatile unsigned char *)allocation = 42;
    return NULL;
}
int main(void) {
    pthread_t worker;
    if (pthread_create(&worker, NULL, allocate_in_worker, NULL) != 0) return 2;
    if (pthread_join(worker, NULL) != 0) return 3;
    return allocation_failed ? 4 : 0;
}
CEOF
cat > /tmp/eigs_asan_gfx_clean.c <<'CEOF'
#include <pthread.h>
#include <stdlib.h>
static int allocation_failed;
static void *allocate_in_worker(void *arg) {
    (void)arg;
    void *allocation = malloc(1234);
    if (!allocation) {
        allocation_failed = 1;
        return NULL;
    }
    *(volatile unsigned char *)allocation = 42;
    free(allocation);
    return NULL;
}
int main(void) {
    pthread_t worker;
    if (pthread_create(&worker, NULL, allocate_in_worker, NULL) != 0) return 2;
    if (pthread_join(worker, NULL) != 0) return 3;
    return allocation_failed ? 4 : 0;
}
CEOF
CTRL_CFLAGS="-fsanitize=address -fno-omit-frame-pointer -g -O0"
if "$CC" -Werror=switch -Werror=comment -Werror=misleading-indentation $CTRL_CFLAGS /tmp/eigs_asan_gfx_leak.c  -lpthread -o /tmp/eigs_asan_gfx_leak  2>/dev/null \
&& "$CC" -Werror=switch -Werror=comment -Werror=misleading-indentation $CTRL_CFLAGS /tmp/eigs_asan_gfx_clean.c -lpthread -o /tmp/eigs_asan_gfx_clean 2>/dev/null; then
    # The integrated LSan control must finish with its expected failure exit;
    # printing a leak and then hanging or dying by signal is not a control pass.
    if leak_reported /tmp/eigs_asan_gfx_leak && [ "$LAST_RC" -eq 1 ]; then
        ok "positive control: a deliberate 1234-byte leak IS reported"
    else
        bad "positive control: a deliberate leak did not finish with the expected LSan failure (rc=$LAST_RC) — the corpus verdict would be unvalidated"
        printf '%s\n' "$LAST_OUT"
        CTRL_OK=0
    fi
    leak_reported /tmp/eigs_asan_gfx_clean; CLEAN_CLASS=$?
    if [ "$CLEAN_CLASS" -eq 2 ] && [ "$LAST_RC" -eq 0 ]; then
        ok "negative control: a leak-free program is clean"
    else
        bad "negative control: a leak-free program did not exit cleanly (rc=$LAST_RC class=$CLEAN_CLASS)"
        printf '%s\n' "$LAST_OUT"
        CTRL_OK=0
    fi
else
    bad "could not compile the leak controls; the corpus verdict would be unvalidated"
    CTRL_OK=0
fi
rm -f /tmp/eigs_asan_gfx_leak.c /tmp/eigs_asan_gfx_clean.c \
      /tmp/eigs_asan_gfx_leak /tmp/eigs_asan_gfx_clean

if [ "$CTRL_OK" != 1 ]; then
    echo "ASan gfx: $PASS passed, $FAIL failed"
    exit 1
fi

if [ "$TOOLCHAIN_ONLY" -eq 1 ]; then
    echo "ASan gfx toolchain: $PASS passed, $FAIL failed"
    exit 0
fi

# ---------------------------------------------------------------- the binary
# Prefer an artifact `make asan-gfx` already produced, but ONLY when it is
# newer than every source it was built from. A stale prebuilt is the vacuity
# hazard here: the section would report on code that is no longer in the tree
# and read exactly like a pass.
BIN=""
if [ -n "${EIGS_ASAN_GFX:-}" ] && [ -x "${EIGS_ASAN_GFX}" ]; then
    BIN="$EIGS_ASAN_GFX"
    echo "  using EIGS_ASAN_GFX=$BIN"
elif [ -z "${EIGS_ASAN_GFX_CC:-}" ] \
     && [ -x "$ROOT/build/asan-gfx/eigenscript" ] \
     && [ -z "$(find "$ROOT/src" -name '*.c' -newer "$ROOT/build/asan-gfx/eigenscript" -print -quit 2>/dev/null)" ] \
     && [ -z "$(find "$ROOT/src" -name '*.h' -newer "$ROOT/build/asan-gfx/eigenscript" -print -quit 2>/dev/null)" ]; then
    BIN="$ROOT/build/asan-gfx/eigenscript"
    echo "  using build/asan-gfx/eigenscript (newer than every src/*.c and src/*.h)"
else
    # Build our own, into /tmp. Deliberately NOT `make asan-gfx`: the runner
    # re-points src/eigenscript per variant and its #681 fingerprint guard
    # fails the suite when the alias moves mid-run. Sources come from the
    # Makefile's own variable so a hand-copied list cannot drift (#223).
    SRCS=$(make -C "$ROOT" -s print-SRC_V_asan-gfx 2>/dev/null)
    if [ -z "$SRCS" ]; then
        bad "could not read SRC_V_asan-gfx from the Makefile"
        echo "ASan gfx: $PASS passed, $FAIL failed"
        exit 1
    fi
    if ! ( cd "$ROOT" && "$CC" -Werror=switch -Werror=comment -Werror=misleading-indentation $ASAN_CFLAGS \
        -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_MODEL=0 -DEIGENSCRIPT_EXT_DB=0 \
        -DEIGENSCRIPT_EXT_GFX=1 '-DEIGENSCRIPT_VERSION="asan_gfx_gate"' \
        $SRCS -o /tmp/eigs_asan_gfx -lm -lpthread -ldl ) 2>/tmp/eigs_asan_gfx.log; then
        cat /tmp/eigs_asan_gfx.log
        bad "asan-gfx build failed"
        echo "ASan gfx: $PASS passed, $FAIL failed"
        exit 1
    fi
    BIN=/tmp/eigs_asan_gfx
    echo "  built /tmp/eigs_asan_gfx from SRC_V_asan-gfx"
fi

# The BINARY under test is an AddressSanitizer build. Decisive about
#     $BIN specifically, which the two program controls above are not: they
#     prove the toolchain and the predicate, not which binary was picked.
if command -v nm >/dev/null 2>&1 && nm "$BIN" 2>/dev/null | grep -q __asan; then
    ok "the binary under test links AddressSanitizer (__asan* present)"
elif command -v nm >/dev/null 2>&1 && nm -D "$BIN" 2>/dev/null | grep -q __asan; then
    # Stripped ELF binaries can retain dynamic ASan imports. Mach-O's nm
    # rejects -D, so its ordinary symbol table is checked first above.
    ok "the binary under test links AddressSanitizer (dynamic __asan* present)"
else
    bad "the binary at $BIN carries no AddressSanitizer symbols — a clean corpus below would mean nothing"
    CTRL_OK=0
fi

if [ "$CTRL_OK" != 1 ]; then
    echo "ASan gfx: $PASS passed, $FAIL failed"
    exit 1
fi

# --------------------------------------------------------------- vacuity
# The binary must actually CONTAIN the surface under test. A default build
# answers "undefined variable" for every gfx name, and a corpus that never
# enters ext_gfx.c reports leak-free for the uninteresting reason.
echo 'print of (gfx_text_width of ["m", 1])' > /tmp/eigs_asan_gfx_probe.eigs
PROBE_OUT="$($TMO "$BIN" /tmp/eigs_asan_gfx_probe.eigs 2>&1)"
PROBE_RC=$?
rm -f /tmp/eigs_asan_gfx_probe.eigs
case "$PROBE_OUT" in
    *"undefined variable"*) skip "the binary at $BIN has no gfx builtins (not an EIGENSCRIPT_EXT_GFX build)" ;;
esac
if [ "$PROBE_RC" -ne 0 ]; then
    bad "gfx binary cannot execute the builtin probe (rc=$PROBE_RC)"
    printf '%s\n' "$PROBE_OUT"
    echo "ASan gfx: $PASS passed, $FAIL failed"
    exit 1
fi

N_FILES=0
for f in "$CORPUS"/*.eigs; do [ -f "$f" ] && N_FILES=$((N_FILES + 1)); done
if [ "$N_FILES" -lt 5 ]; then
    bad "corpus has $N_FILES programs (floor 5) — tests/gfx_asan_corpus/ lost ground"
    echo "ASan gfx: $PASS passed, $FAIL failed"
    exit 1
fi

# ---------------------------------------------------------------- the corpus
# Each program runs in BOTH modes. The strict pass is not decoration: it is
# the only one that walks the RAISE path of every #1007 guard, and a guard
# that raises after allocating its answer leaks exactly there.
for f in "$CORPUS"/*.eigs; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    for mode in plain strict; do
        if [ "$mode" = strict ]; then
            if EIGS_STRICT=1 leak_reported "$BIN" "$f"; then LEAK=1; else LEAK=0; fi
        else
            if leak_reported "$BIN" "$f"; then LEAK=1; else LEAK=0; fi
        fi
        # Startup failures and signals cannot masquerade as clean corpus rows.
        lsan_classify "$LAST_OUT"; CLASS=$?
        RC_OK=0
        [ "$LAST_RC" -eq 0 ] && RC_OK=1
        if [ "$base" = 06_rejected.eigs ] && [ "$mode" = strict ] \
             && [ "$LAST_RC" -eq 1 ] \
             && printf '%s\n' "$LAST_OUT" | grep -Eq '^Error line [0-9]+: gfx_rect: expected \[number x, number y, number w, number h, number r, number g, number b\] and an optional number alpha$'; then RC_OK=1; fi
        if [ "$LEAK" = 0 ] && [ "$CLASS" = 2 ] && [ "$RC_OK" = 1 ]; then
            ok "$base [$mode] clean under ASan+UBSan+LSan"
        else
            bad "$base [$mode] leak=$LEAK sanitizer-class=$CLASS rc=$LAST_RC"
            printf '%s\n' "$LAST_OUT" | tail -8 | sed 's/^/        /'
            case "$LAST_RC" in
                124|137)
                    echo "ASan gfx: $PASS passed, $FAIL failed"
                    exit 1 ;;
            esac
        fi
    done
done

# Say what the environment could not exercise rather than letting a green
# line imply it did.
echo 'o is gfx_open of [8, 8, "probe"]
print of f"sdl-present: {o}"
ignore is gfx_close of null' > /tmp/eigs_asan_gfx_sdl.eigs
SDL_OUT="$($TMO "$BIN" /tmp/eigs_asan_gfx_sdl.eigs 2>&1)"
SDL_RC=$?
rm -f /tmp/eigs_asan_gfx_sdl.eigs
lsan_classify "$SDL_OUT"; SDL_CLASS=$?
if [ "$SDL_RC" -ne 0 ] || [ "$SDL_CLASS" -ne 2 ]; then
    bad "SDL availability probe failed (rc=$SDL_RC sanitizer-class=$SDL_CLASS)"
    printf '%s\n' "$SDL_OUT"
    echo "ASan gfx: $PASS passed, $FAIL failed"
    exit 1
fi
printf '%s' "$SDL_OUT" | grep -q "sdl-present: 1" \
    || echo "  NOTE: libSDL2 absent — the corpus exercised the argument and"\
            "allocation paths but no real renderer or audio device."

echo "ASan gfx: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
exit 0
