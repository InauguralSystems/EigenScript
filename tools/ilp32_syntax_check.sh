#!/usr/bin/env bash
# ILP32 syntax gate — the playground's wasm32 build cannot break unnoticed.
#
# pages.yml compiles the web/build.sh SOURCES with emcc (wasm32). A _Static_assert
# that was true only at 64-bit pointer width (#1183's "union sized by fn") kept
# that lane red from bcdd99f (#1185). This gate runs the same recipe locally
# without emcc: clang -m32 -fsyntax-only over EVERY translation unit that
# web/build.sh passes to emcc, with the same -D flags that script uses.
#
# Population is DERIVED from web/build.sh's SOURCES=(...) array — every entry,
# no directory filter, no sibling list. Round 1 filtered the array to src/*.c
# and so examined 22 of the 23 TUs emcc compiles: web/eigs_wasm.c, the
# playground's entry point, sat outside the gate AND outside its self-test, and
# a compile error planted in it passed both (measured 2026-09-21). The
# assertion is examined == len(SOURCES) > 0, floored; an empty inventory is
# FAIL, not a clean tree.
#
# web/eigs_wasm.c includes <emscripten.h>, which a box without emsdk does not
# have. The gate writes a STUB into its own temp include dir defining the one
# macro that file uses (EMSCRIPTEN_KEEPALIVE) as a no-op, and passes
# -DEMSCRIPTEN (implicit under emcc) so any #ifdef EMSCRIPTEN arm takes the
# same branch. Plant 1b is what proves the stub cannot mask a real error.
#
# LIMIT, not a fix: -m32 is the i386 ABI, NOT wasm32. `double` aligns to 4 on
# i386 and to 8 on wasm32, so this stand-in catches pointer-width breaks — the
# #1185 class, and what kept the lane red — not every layout difference the
# real emcc build can hit.
#
# Usage: tools/ilp32_syntax_check.sh [--selftest]
#   --selftest : plant (1) the old sizeof(data)==sizeof(fn) assert, (1b) a
#                syntax error in a scratch copy of the playground entry point,
#                (2) an empty TU list, (3) a population below the floor, and
#                (3b) a SOURCES array with web/eigs_wasm.c removed; all five
#                must go RED through the real compile/examine functions (not a
#                re-implementation), and the live inventory must stay green.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd)

# emcc is handed -DEIGENSCRIPT_VERSION from the VERSION file (web/build.sh's
# emcc line). web/eigs_wasm.c's eigs_version() returns that macro, so the TU
# does not compile without it. Read it the same way that script does.
EIGS_VERSION=$(cat "$REPO/VERSION" 2>/dev/null || echo dev)

SELFTEST=0
[ "${1:-}" = "--selftest" ] && SELFTEST=1

# Floor on the derived population. Measured 2026-09-21: web/build.sh SOURCES
# lists 23 TUs and all 23 are examined — the 22 src/*.c runtime units plus
# web/eigs_wasm.c, the playground entry point emcc compiles on the same line.
# Adding a source raises the count and needs no edit; a DECREASE is a
# deliberate re-pin. Plant 3b is the case that matters: dropping the entry
# point from SOURCES takes the population to 22, which this floor calls RED.
TU_FLOOR="${EIGS_ILP32_TU_FLOOR:-23}"

# Playground -D flags, from web/build.sh (the pages.yml compile). Inlined on
# the clang line as well — the werror gate reads SOURCE TEXT, not expansions.

# Extract EVERY TU from web/build.sh SOURCES=(...). Ask the file; do not keep a
# sibling list, and do NOT filter by directory: web/eigs_wasm.c rides the same
# emcc invocation as the src/*.c units, and filtering it out is exactly the
# examines-fewer-than-it-says failure this gate exists to prevent. ("src" in
# the function name reads as "source", not "src/"; reproducers outside the repo
# source this function by name, so the name is stable.)
# awk character class is [ \t], not [[:space:]] (POSIX awk).
extract_src_tus() {
    awk '
        /^SOURCES=\(/ { in_arr = 1; next }
        in_arr && /^\)/ { exit }
        in_arr {
            n = split($0, a, /[ \t]+/)
            for (i = 1; i <= n; i++) {
                s = a[i]
                gsub(/^[ \t]+/, "", s)
                gsub(/[ \t\\]+$/, "", s)
                if (s ~ /\.c$/) print s
            }
        }
    ' "$1"
}

# $1 = translation unit path (repo-relative or absolute). $2 = optional extra
# -I dir, prepended so a planted header wins. $3 = optional stub dir.
# Diagnostics on stderr; status is the return value. Do not print a verdict
# here — examine_tus owns the inventory report.
#
# Quoted includes search the SOURCE FILE's directory before -I, so compiling
# src/eigenscript.c with -I<scratch> still reads src/eigenscript.h. The plant
# therefore compiles a probe sitting next to the planted header.
compile_tu() {
    local tu="$1" extra_i="${2:-}" stubdir="${3:-${STUB:-}}"
    local out st inc
    inc="-Isrc"
    [ -n "$extra_i" ] && inc="-I$extra_i -Isrc"
    # Status captured DIRECTLY. $? after a pipeline is the last stage.
    # Flag literals (not $VAR) so tools/werror_switch_check.sh can see them.
    # -c is load-bearing for that recognizer; -fsyntax-only is the actual work.
    out=$(clang -m32 -fsyntax-only -c \
        -Werror=switch -Werror=comment -Werror=misleading-indentation \
        -isystem "$stubdir" -isystem /usr/include/x86_64-linux-gnu \
        $inc \
        -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_MODEL=0 -DEIGENSCRIPT_EXT_DB=0 \
        -DEMSCRIPTEN -DEIGENSCRIPT_VERSION="\"$EIGS_VERSION\"" \
        "$tu" 2>&1)
    st=$?
    if [ "$st" -ne 0 ]; then
        echo "FAIL: $tu" >&2
        printf '%s\n' "$out" | sed 's/^/      /' >&2
        return 1
    fi
    return 0
}

# $1 = file of TU paths, one per line. $2 = extra -I. $3 = stub dir.
# $4 = floor on the population (0 = only the non-empty rule).
# Asserts examined == len(list) > 0. Empty inventory is FAIL, not PASS with 0.
#
# The floor is the second half of that rule (mechanical-gates §43): the
# population is DERIVED from web/build.sh, and a derived population shrinks
# silently. `> 0` catches losing ALL of them and nothing else — dropping 22 of
# 23 SOURCES entries would still print OK. The floor turns a shrink into a
# review event; raising it needs no edit.
examine_tus() {
    local list="$1" extra_i="${2:-}" stubdir="${3:-${STUB:-}}" floor="${4:-0}"
    local n=0 n_ok=0 n_fail=0 tu
    while IFS= read -r tu || [ -n "$tu" ]; do
        [ -z "$tu" ] && continue
        n=$((n + 1))
        if compile_tu "$tu" "$extra_i" "$stubdir"; then
            n_ok=$((n_ok + 1))
        else
            n_fail=$((n_fail + 1))
        fi
    done < "$list"
    if [ "$n" -eq 0 ]; then
        echo "FAIL: examined 0 playground TUs — empty inventory, not clean" >&2
        return 1
    fi
    if [ "$n" -lt "$floor" ]; then
        echo "FAIL: examined $n playground TUs, floor is $floor — web/build.sh SOURCES shrank; re-pin the floor deliberately or restore the sources" >&2
        return 1
    fi
    if [ "$n_ok" -ne "$n" ]; then
        echo "FAIL: examined $n TUs, $n_ok ok, $n_fail failed (want examined == len(list) > 0)" >&2
        return 1
    fi
    echo "OK: examined $n ILP32 TUs (every entry of web/build.sh SOURCES)"
    return 0
}

# One stub dir for gnu/stubs-32.h (glibc does not ship it on a 64-bit-only box).
# Created here, never left in the tree. The selftest process has its own copy.
STUB=$(mktemp -d "${TMPDIR:-/tmp}/eigs-ilp32-stub-XXXXXX")
mkdir -p "$STUB/gnu"
: > "$STUB/gnu/stubs-32.h"
# <emscripten.h> stub: the playground entry point includes it and a box without
# emsdk has no such header. Define ONLY the macro web/eigs_wasm.c uses, as a
# no-op — a stub that defined more would start hiding real errors. Plant 1b
# compiles a planted syntax error through this very stub and requires RED.
printf '%s\n' '#ifndef EIGS_ILP32_STUB_EMSCRIPTEN_H' \
               '#define EIGS_ILP32_STUB_EMSCRIPTEN_H' \
               '#define EMSCRIPTEN_KEEPALIVE' \
               '#endif' > "$STUB/emscripten.h"
trap 'rm -rf -- "${STUB:-}" "${WORK:-}"' EXIT

# AVAILABILITY IS A CAPABILITY, NOT A NAME. A `command -v` probe on the
# compiler's name is true on the macOS runners, where `-m32` has no target at
# all (Apple dropped 32-bit) and /usr/include/x86_64-linux-gnu does not exist —
# so a name probe would turn this gate into a NEW red lane on runners it has
# nothing to say about, which is the opposite of why it exists. There is no
# separate name test either: an absent toolchain fails this same probe with the
# shell's own "command not found", so ONE path covers both, and no line in this
# file names a compiler outside an actual compile invocation (a name on any
# other line is an unaccounted-shape failure in [99i]'s recognizer coverage).
#
# The skip is announced with the toolchain's own words (mechanical-gates §155:
# a skip is a claim, and a silent one reads as coverage). If the Linux lane
# ever starts skipping, the reason is printed right there.
printf '%s\n' 'int eigs_ilp32_probe(void) { return 0; }' > "$STUB/probe_avail.c"
# The -Werror= trio is not load-bearing for a one-line probe; it is here
# because tools/werror_switch_check.sh audits every compile line in this
# script by SOURCE TEXT, and an audited line without them is a violation.
if ! avail_err=$(clang -m32 -fsyntax-only -c \
        -Werror=switch -Werror=comment -Werror=misleading-indentation \
        -isystem "$STUB" -isystem /usr/include/x86_64-linux-gnu \
        "$STUB/probe_avail.c" 2>&1); then
    echo "SKIP: no 32-bit C target on this toolchain — the playground's 32-bit shape was NOT checked"
    printf '%s\n' "$avail_err" | sed 's/^/      /'
    exit 0
fi

if [ "$SELFTEST" -eq 0 ]; then
    tus=$(mktemp "${TMPDIR:-/tmp}/eigs-ilp32-tus-XXXXXX")
    extract_src_tus "$REPO/web/build.sh" > "$tus"
    examine_tus "$tus" "" "$STUB" "$TU_FLOOR"
    st=$?
    rm -f "$tus"
    exit $st
fi

# ---- selftest: plant the three faults through the REAL functions ----------
fails=0
WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs-ilp32-st-XXXXXX")

# Plant 1: copy the tree's eigenscript.h, re-insert the OLD assert
#   sizeof(((Value *)0)->data) == sizeof(((Value *)0)->data.fn)
# then compile src/eigenscript.c with -I<scratch> first. The gate's compile_tu
# must go RED. (Do not restore from git — the live header is already the fix.)
cp "$REPO/src/eigenscript.h" "$WORK/eigenscript.h"
# Unique substring: only the third _Static_assert uses `data.strv) <=`.
if ! grep -q 'data\.strv) <= sizeof' "$WORK/eigenscript.h"; then
    echo "selftest FAIL: live header does not carry the ILP32-safe assert — plant cannot be installed"
    fails=1
else
    # portable sed: write-to-temp + mv, then cmp-verify the edit landed.
    sed 's/data\.strv) <= sizeof/data) == sizeof/' "$WORK/eigenscript.h" > "$WORK/eigenscript.h.planted"
    if cmp -s "$WORK/eigenscript.h" "$WORK/eigenscript.h.planted"; then
        echo "selftest FAIL: plant 1 sed was a no-op — the old assert was not inserted"
        fails=1
    else
        mv "$WORK/eigenscript.h.planted" "$WORK/eigenscript.h"
        if grep -q 'data\.strv) <= sizeof' "$WORK/eigenscript.h"; then
            echo "selftest FAIL: plant 1 still has the live assert after the rewrite"
            fails=1
        else
            # Probe lives next to the planted header so "eigenscript.h" resolves
            # to the mutant (quoted includes search the source file's directory
            # before -I). The recipe is compile_tu — not a re-typed clang line.
            printf '%s\n' '#include "eigenscript.h"' > "$WORK/probe.c"
            if compile_tu "$WORK/probe.c" "$WORK" "$STUB" 2>"$WORK/plant1.err"; then
                echo "selftest FAIL: plant 1 (old sizeof(data)==sizeof(fn) assert) compiled clean — the ILP32 check did not go RED"
                fails=1
            elif grep -q 'static assertion failed' "$WORK/plant1.err"; then
                echo "selftest ok: plant 1 old sizeof(data)==sizeof(fn) assert is RED at ILP32"
            else
                echo "selftest FAIL: plant 1 went red for the wrong reason:"
                sed 's/^/      /' "$WORK/plant1.err"
                fails=1
            fi
        fi
    fi
fi

# Plant 1b: a SYNTAX ERROR in a scratch copy of the playground entry point.
# This is the fault round 1's gate could not see at all: web/eigs_wasm.c was
# outside both the inventory and this self-test, so a broken entry point was
# green twice over (Astra/Fable, 2026-09-21). It is also what keeps the
# <emscripten.h> stub honest — if the stub were masking errors, the planted one
# would compile too. The CLEAN copy is compiled first through the identical
# path: without that control, a red plant could be the copy mechanism rather
# than the fault. The copy lives in a tree whose ../src resolves, because the
# file's own includes are "../src/...".
mkdir -p "$WORK/tree/web"
ln -sfn "$REPO/src" "$WORK/tree/src"
SHIM_TU="web/eigs_wasm.c"
# Derived ONCE into a file, then read from it: a pipeline must not decide a
# verdict under pipefail (#1122, tools/pipefail_verdict_check.sh).
extract_src_tus "$REPO/web/build.sh" > "$WORK/live.tus"
N_LIVE_TUS=$(grep -c . "$WORK/live.tus")
if ! [ -f "$REPO/$SHIM_TU" ]; then
    echo "selftest FAIL: plant 1b cannot run — $SHIM_TU is not in the tree"
    fails=1
elif ! grep -qx "$SHIM_TU" "$WORK/live.tus"; then
    echo "selftest FAIL: plant 1b cannot run — $SHIM_TU is not in the derived inventory (the gate is back to examining fewer TUs than emcc compiles)"
    fails=1
else
    cp "$REPO/$SHIM_TU" "$WORK/tree/web/eigs_wasm.c"
    if ! compile_tu "$WORK/tree/web/eigs_wasm.c" "" "$STUB" 2>"$WORK/plant1b-clean.err"; then
        echo "selftest FAIL: plant 1b control — the UNPLANTED copy of $SHIM_TU does not compile, so a red plant would prove nothing:"
        sed 's/^/      /' "$WORK/plant1b-clean.err"
        fails=1
    else
        printf '%s\n' 'int eigs_ilp32_plant_1b(void) { return 1 }' >> "$WORK/tree/web/eigs_wasm.c"
        if compile_tu "$WORK/tree/web/eigs_wasm.c" "" "$STUB" 2>"$WORK/plant1b.err"; then
            echo "selftest FAIL: plant 1b (syntax error in $SHIM_TU) compiled clean — the playground entry point is not really being examined"
            fails=1
        elif grep -q "expected ';'" "$WORK/plant1b.err"; then
            echo "selftest ok: plant 1b a syntax error in the playground entry point is RED at ILP32"
        else
            echo "selftest FAIL: plant 1b went red for the wrong reason:"
            sed 's/^/      /' "$WORK/plant1b.err"
            fails=1
        fi
    fi
fi

# Plant 2: empty TU list → examine_tus must FAIL (not PASS with 0 examined).
: > "$WORK/empty.tus"
if examine_tus "$WORK/empty.tus" "" "$STUB" >/dev/null 2>"$WORK/empty.err"; then
    echo "selftest FAIL: plant 2 (empty TU list) passed — a zero inventory must be FAIL, not PASS with 0 examined"
    fails=1
else
    if grep -q 'examined 0' "$WORK/empty.err" || grep -q 'empty inventory' "$WORK/empty.err"; then
        echo "selftest ok: plant 2 empty TU list is FAIL (not PASS with 0 examined)"
    else
        echo "selftest FAIL: plant 2 went red for the wrong reason:"
        sed 's/^/      /' "$WORK/empty.err"
        fails=1
    fi
fi

# Plant 3: a population BELOW the floor -> examine_tus must FAIL. `> 0` alone
# cannot see a derived list that shrank from 22 to 1; this is the plant that
# makes the floor non-vacuous (mechanical-gates §43). Built from the live list
# so the TU compiles cleanly and the ONLY thing wrong is the population size.
extract_src_tus "$REPO/web/build.sh" | head -1 > "$WORK/short.tus"
if ! [ -s "$WORK/short.tus" ]; then
    echo "selftest FAIL: plant 3 could not build a 1-entry TU list from web/build.sh"
    fails=1
elif examine_tus "$WORK/short.tus" "" "$STUB" "$TU_FLOOR" >/dev/null 2>"$WORK/short.err"; then
    echo "selftest FAIL: plant 3 (population of 1 against a floor of $TU_FLOOR) passed — the floor is vacuous"
    fails=1
else
    if grep -q "floor is $TU_FLOOR" "$WORK/short.err"; then
        echo "selftest ok: plant 3 a shrunk population (1 of $TU_FLOOR) is FAIL"
    else
        echo "selftest FAIL: plant 3 went red for the wrong reason:"
        sed 's/^/      /' "$WORK/short.err"
        fails=1
    fi
fi

# Plant 3b: the playground entry point REMOVED from a scratch copy of
# web/build.sh's SOURCES. This is plant 3 aimed at the exact shrink that
# happened for real — the population falls from 23 to 22 and the floor must
# call it RED. Plant 3 uses a 1-entry list, which any floor > 1 catches; 3b is
# the off-by-one that a floor of 22 would have waved through.
sed '/^ *web\/eigs_wasm\.c *$/d' "$REPO/web/build.sh" > "$WORK/build_noshim.sh"
if cmp -s "$REPO/web/build.sh" "$WORK/build_noshim.sh"; then
    echo "selftest FAIL: plant 3b sed was a no-op — web/eigs_wasm.c was not removed from the scratch SOURCES"
    fails=1
else
    extract_src_tus "$WORK/build_noshim.sh" > "$WORK/noshim.tus"
    n_noshim=$(grep -c . "$WORK/noshim.tus")
    n_live="$N_LIVE_TUS"
    if [ "$n_noshim" -ne $((n_live - 1)) ]; then
        echo "selftest FAIL: plant 3b removed $((n_live - n_noshim)) TU(s), not exactly 1 (live=$n_live planted=$n_noshim)"
        fails=1
    elif examine_tus "$WORK/noshim.tus" "" "$STUB" "$TU_FLOOR" >/dev/null 2>"$WORK/noshim.err"; then
        echo "selftest FAIL: plant 3b (SOURCES minus the playground entry point, $n_noshim of $TU_FLOOR) passed — the floor cannot see the entry point leave"
        fails=1
    elif grep -q "examined $n_noshim playground TUs, floor is $TU_FLOOR" "$WORK/noshim.err"; then
        echo "selftest ok: plant 3b dropping the playground entry point ($n_noshim of $TU_FLOOR) is FAIL"
    else
        echo "selftest FAIL: plant 3b went red for the wrong reason:"
        sed 's/^/      /' "$WORK/noshim.err"
        fails=1
    fi
fi

# Control: the live inventory must still be green, or the selftest has broken
# the compile function. Re-derive from web/build.sh, same as production —
# including the floor, so the control mirrors the production call exactly.
extract_src_tus "$REPO/web/build.sh" > "$WORK/live.tus"
if ! examine_tus "$WORK/live.tus" "" "$STUB" "$TU_FLOOR" >/dev/null; then
    echo "selftest FAIL: live inventory went red during --selftest — the plants contaminated compile_tu"
    fails=1
else
    echo "selftest ok: live inventory still green after the plants"
fi

if [ "$fails" -eq 0 ]; then
    echo "selftest: all planted faults caught"
    exit 0
fi
exit 1
