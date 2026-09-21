#!/usr/bin/env bash
# ILP32 syntax gate — the playground's wasm32 build cannot break unnoticed.
#
# pages.yml compiles the web/build.sh SOURCES with emcc (wasm32). A _Static_assert
# that was true only at 64-bit pointer width (#1183's "union sized by fn") kept
# that lane red from bcdd99f (#1185). This gate runs the same recipe locally
# without emcc: clang -m32 -fsyntax-only over EVERY translation unit that
# web/build.sh passes to emcc, with the -D set below.
#
# Population is DERIVED from web/build.sh's SOURCES=(...) array — every entry,
# no directory filter, no sibling list. Round 1 filtered the array to src/*.c
# and so examined 22 of the 23 TUs emcc compiles: web/eigs_wasm.c, the
# playground's entry point, sat outside the gate AND outside its self-test, and
# a compile error planted in it passed both (measured 2026-09-21). The
# assertion is examined == len(SOURCES) > 0, floored; an empty inventory is
# FAIL, not a clean tree.
#
# SOURCES IS NOT THE WHOLE COMPILE LINE. The derived population can only see
# what the array holds; a `.c` written directly onto the emcc invocation is a
# TU emcc compiles and this gate never touches — measured 2026-09-21 as 24
# actual arguments against 23 examined. So the invocation itself is audited:
# check_sources_only() joins the continuation lines of the command that expands
# "${SOURCES[@]}" and FAILS BY NAME on any other token ending in `.c`. Its
# plant is 2c. Residual, stated rather than implied: a token that reaches the
# compiler through a shell variable, or a SECOND compile command elsewhere in
# that script, is outside both the array and this audit.
#
# DEFINE PARITY. Round 2 defined the bare name `EMSCRIPTEN` and claimed that
# was "exactly as the emcc line passes them". Measured 2026-09-21: web/build.sh's
# emcc line defines no such macro, and `clang --target=wasm32-unknown-emscripten
# -E -dM` predefines __EMSCRIPTEN__, __wasm__, __wasm32__ (plus the alias
# spellings __wasm / __wasm32 and the __wasm_*__ feature macros) and does NOT
# define EMSCRIPTEN — the bare name is a legacy emcc macro that STRICT mode
# does not emit. No TU in SOURCES tests EMSCRIPTEN. The one conditional in the
# population keyed on this world is src/jit.c:110 `#if !defined(__wasm__)`, and
# under round 2's flags the gate compiled the __builtin___clear_cache arm that
# emcc never sees, i.e. it took the OPPOSITE branch from the lane it stands in
# for. So compile_tu now defines __EMSCRIPTEN__, __wasm__ and __wasm32__, and
# not the bare name. Plant 1c is the case that proves it: an `#ifdef
# __EMSCRIPTEN__ / #error` arm was GREEN under the old flags and is RED under
# these. (The flag literals themselves are on compile_tu's clang line and
# nowhere else in this file, so a grep for the gate's -D set reads the
# invocation rather than this paragraph.)
#
# THE STUB DEFINES THE REAL MACRO, NOT A NO-OP. web/eigs_wasm.c includes
# <emscripten.h>, which a box without emsdk does not have, so the gate writes
# its own into a temp include dir. Round 2 stubbed EMSCRIPTEN_KEEPALIVE as
# empty, which erased a SYNTAX constraint: `EMSCRIPTEN_KEEPALIVE return x;`
# compiled clean under the gate and is RED under emscripten's real header
# ("'used' attribute cannot be applied to a statement"). The stub now carries
# em_macros.h's actual definition, __attribute__((used)); plant 1d is that
# mutant. EMSCRIPTEN_KEEPALIVE is the only macro the entry point uses today —
# read the file before assuming. The first real emscripten_*() API CALL in that
# entry point turns this gate RED by name with an implicit-declaration error,
# because the stub carries no prototypes; that is the intended signal to extend
# the stub with the real declaration, not to silence it.
#
# LIMIT, not a fix: -m32 is the i386 ABI, NOT wasm32. `double` aligns to 4 on
# i386 and to 8 on wasm32, so this stand-in catches pointer-width breaks — the
# #1185 class, and what kept the lane red — not every layout difference the
# real emcc build can hit.
#
# Usage: tools/ilp32_syntax_check.sh [--selftest]
#   --selftest : plant (1) the old sizeof(data)==sizeof(fn) assert, (1b) a
#                syntax error in a scratch copy of the playground entry point,
#                (1c) an emcc-only #error arm in that file, (1d) the misplaced
#                EMSCRIPTEN_KEEPALIVE attribute, (2) an empty TU list, (2c) a
#                `.c` literal on the compile line outside SOURCES, (3) a
#                population below the floor, and (3b) the entry point dropped
#                from the evaluated inventory; plus two controls — a
#                REFORMATTED SOURCES array must yield the identical inventory,
#                and the live inventory must stay green. All of them run
#                through the real compile/examine/audit functions, not a
#                re-implementation.
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
# point from the inventory takes the population to 22, which this floor calls
# RED.
TU_FLOOR="${EIGS_ILP32_TU_FLOOR:-23}"

# Extract EVERY TU from web/build.sh SOURCES=(...). Ask the file; do not keep a
# sibling list, and do NOT filter by directory: web/eigs_wasm.c rides the same
# emcc invocation as the src/*.c units, and filtering it out is exactly the
# examines-fewer-than-it-says failure this gate exists to prevent. ("src" in
# the function name reads as "source", not "src/"; reproducers outside the repo
# source this function by name, so the name is stable.)
#
# FORMAT-INDEPENDENT by construction: entries are taken from anywhere between
# the `SOURCES=(` and the closing `)`, including tokens sharing those two
# lines, so reflowing the array cannot change the inventory. The round-2
# version skipped the opening line whole, which meant a one-line array read as
# EMPTY. The reformat control in --selftest is what holds this.
# awk character class is [ \t], not [[:space:]] (POSIX awk).
extract_src_tus() {
    awk '
        {
            line = $0
            if (!in_arr) {
                if (line !~ /^SOURCES=\(/) next
                sub(/^SOURCES=\(/, "", line)
                in_arr = 1
            }
            if (line ~ /\)/) { sub(/\).*$/, "", line); done = 1 }
            n = split(line, a, /[ \t]+/)
            for (i = 1; i <= n; i++) {
                s = a[i]
                gsub(/[ \t\\"]+/, "", s)
                if (s ~ /\.c$/) print s
            }
            if (done) exit
        }
    ' "$1"
}

# Every token ending in `.c` on the joined command line that expands
# "${SOURCES[@]}", EXCLUDING the array expansion itself. Continuation lines are
# joined first, and the SOURCES=(...) block is skipped, so what remains is what
# the invocation names directly. Prints offenders on stdout and nothing else —
# the caller owns the verdict text.
extra_tus_on_compile_line() {
    awk '
        /^SOURCES=\(/ { in_arr = 1 }
        in_arr { if ($0 ~ /\)/) in_arr = 0; next }
        {
            l = $0
            if (l ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, "", l); buf = buf " " l; next }
            buf = buf " " l
            if (buf ~ /SOURCES\[@\]/) {
                n = split(buf, a, /[ \t]+/)
                for (i = 1; i <= n; i++) {
                    t = a[i]
                    gsub(/^"+|"+$/, "", t)
                    if (t ~ /\.c$/) print t
                }
            }
            buf = ""
        }
    ' "$1"
}

# $1 = the build script to audit. FAIL BY NAME when the compile line names a
# translation unit the derived inventory cannot see.
check_sources_only() {
    local f="$1" extra
    extra=$(extra_tus_on_compile_line "$f")
    if [ -n "$extra" ]; then
        echo "FAIL: the playground compile line names translation unit(s) outside the SOURCES array, so the derived inventory examines fewer TUs than are compiled:" >&2
        printf '%s\n' "$extra" | sed 's/^/      /' >&2
        echo "      Put them in SOURCES=(...) or this gate cannot see them." >&2
        return 1
    fi
    return 0
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
    # The three predefines are the wasm32-emscripten target's, measured with
    # `-E -dM`; the bare EMSCRIPTEN name is NOT among them (see the header).
    out=$(clang -m32 -fsyntax-only -c \
        -Werror=switch -Werror=comment -Werror=misleading-indentation \
        -isystem "$stubdir" -isystem /usr/include/x86_64-linux-gnu \
        $inc \
        -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_MODEL=0 -DEIGENSCRIPT_EXT_DB=0 \
        -D__EMSCRIPTEN__ -D__wasm__ -D__wasm32__ \
        -DEIGENSCRIPT_VERSION="\"$EIGS_VERSION\"" \
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
# emsdk has no such header. EMSCRIPTEN_KEEPALIVE is defined EXACTLY as
# emscripten's system/include/emscripten/em_macros.h defines it, so the macro's
# SYNTAX constraints survive the stand-in (plant 1d). Nothing else is defined:
# the entry point uses no other macro today, and an invented prototype would
# start hiding real errors. Plants 1b/1c/1d compile through this very stub and
# require RED.
printf '%s\n' '#ifndef EIGS_ILP32_STUB_EMSCRIPTEN_H' \
               '#define EIGS_ILP32_STUB_EMSCRIPTEN_H' \
               '#define EMSCRIPTEN_KEEPALIVE __attribute__((used))' \
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
    if ! check_sources_only "$REPO/web/build.sh"; then
        exit 1
    fi
    tus=$(mktemp "${TMPDIR:-/tmp}/eigs-ilp32-tus-XXXXXX")
    extract_src_tus "$REPO/web/build.sh" > "$tus"
    examine_tus "$tus" "" "$STUB" "$TU_FLOOR"
    st=$?
    rm -f "$tus"
    exit $st
fi

# ---- selftest: plant the faults through the REAL functions ----------------
fails=0
WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs-ilp32-st-XXXXXX")

# $1 = key (used for the error file name), $2 = human label, $3 = TU to
# compile, $4 = literal substring the diagnostic must contain. Prints the
# verdict line; sets `fails` on anything but a RED for the stated reason.
expect_tu_red() {
    local key="$1" label="$2" tu="$3" needle="$4" errf
    errf="$WORK/$key.err"
    if compile_tu "$tu" "" "$STUB" 2>"$errf"; then
        echo "selftest FAIL: $label compiled clean — the ILP32 check did not go RED"
        fails=1
        return
    fi
    if grep -qF -- "$needle" "$errf"; then
        echo "selftest ok: $label is RED at ILP32"
    else
        echo "selftest FAIL: $label went red for the wrong reason:"
        sed 's/^/      /' "$errf"
        fails=1
    fi
}

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

# ---- the three entry-point mutants (1b, 1c, 1d) --------------------------
# web/eigs_wasm.c was outside both the inventory and this self-test in round 1,
# so a broken entry point was green twice over (Astra/Fable, 2026-09-21). Each
# mutant gets a FRESH copy of the live file; the CLEAN copy is compiled first
# through the identical path, because without that control a red plant could be
# the copy mechanism rather than the fault. The copy lives in a tree whose
# ../src resolves, since the file's own includes are "../src/...".
mkdir -p "$WORK/tree/web"
ln -sfn "$REPO/src" "$WORK/tree/src"
SHIM_TU="web/eigs_wasm.c"
SHIM_COPY="$WORK/tree/web/eigs_wasm.c"
# Derived ONCE into a file, then read from it: a pipeline must not decide a
# verdict under pipefail (#1122, tools/pipefail_verdict_check.sh).
extract_src_tus "$REPO/web/build.sh" > "$WORK/live.tus"
N_LIVE_TUS=$(grep -c . "$WORK/live.tus")
entry_ok=1
if ! [ -f "$REPO/$SHIM_TU" ]; then
    echo "selftest FAIL: the entry-point plants cannot run — $SHIM_TU is not in the tree"
    fails=1
    entry_ok=0
elif ! grep -qx "$SHIM_TU" "$WORK/live.tus"; then
    echo "selftest FAIL: the entry-point plants cannot run — $SHIM_TU is not in the derived inventory (the gate is back to examining fewer TUs than emcc compiles)"
    fails=1
    entry_ok=0
else
    cp "$REPO/$SHIM_TU" "$SHIM_COPY"
    if ! compile_tu "$SHIM_COPY" "" "$STUB" 2>"$WORK/entry-clean.err"; then
        echo "selftest FAIL: entry-point control — the UNPLANTED copy of $SHIM_TU does not compile, so a red plant would prove nothing:"
        sed 's/^/      /' "$WORK/entry-clean.err"
        fails=1
        entry_ok=0
    fi
fi

if [ "$entry_ok" -eq 1 ]; then
    # 1b: a plain syntax error — the fault round 1's gate could not see at all.
    cp "$REPO/$SHIM_TU" "$SHIM_COPY"
    printf '%s\n' 'int eigs_ilp32_plant_1b(void) { return 1 }' >> "$SHIM_COPY"
    expect_tu_red plant1b "plant 1b a syntax error in the playground entry point" \
        "$SHIM_COPY" "expected ';'"

    # 1c: an arm keyed on the macro the REAL target predefines. Under round 2's
    # bare-name define this compiled clean while emcc saw the #error — the gate
    # took the opposite branch from the lane it stands in for.
    cp "$REPO/$SHIM_TU" "$SHIM_COPY"
    printf '%s\n' '#ifdef __EMSCRIPTEN__' '#error EIGS_ILP32_PLANT_1C' '#endif' >> "$SHIM_COPY"
    expect_tu_red plant1c "plant 1c an emcc-only #ifdef __EMSCRIPTEN__ arm in the playground entry point" \
        "$SHIM_COPY" "EIGS_ILP32_PLANT_1C"

    # 1d: EMSCRIPTEN_KEEPALIVE in statement position. Legal under an EMPTY stub
    # (round 2), RED under em_macros.h's real __attribute__((used)). This is the
    # class a no-op stub erases: syntax constraints, not just names.
    cp "$REPO/$SHIM_TU" "$SHIM_COPY"
    if ! grep -q '^    return EIGENSCRIPT_VERSION;' "$SHIM_COPY"; then
        echo "selftest FAIL: plant 1d cannot be installed — the anchor line in $SHIM_TU moved"
        fails=1
    else
        sed 's/^    return EIGENSCRIPT_VERSION;/    EMSCRIPTEN_KEEPALIVE return EIGENSCRIPT_VERSION;/' \
            "$SHIM_COPY" > "$SHIM_COPY.planted"
        if cmp -s "$SHIM_COPY" "$SHIM_COPY.planted"; then
            echo "selftest FAIL: plant 1d sed was a no-op — the misplaced attribute was not inserted"
            fails=1
        else
            mv "$SHIM_COPY.planted" "$SHIM_COPY"
            expect_tu_red plant1d "plant 1d a misplaced EMSCRIPTEN_KEEPALIVE attribute in the playground entry point" \
                "$SHIM_COPY" "cannot be applied to a statement"
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

# Plant 2c: a `.c` literal appended to the compile line OUTSIDE the array. The
# derived inventory is unchanged (still 23) and every one of them compiles, so
# every other assertion in this file is green — this is the residual that was
# measured as 24 arguments against 23 examined, and check_sources_only is the
# only thing that can see it.
ROGUE_TU="web/eigs_ilp32_rogue_2c.c"
awk -v rogue="$ROGUE_TU" '
    { if ($0 ~ /^[ \t]*-lm[ \t]*\\$/) print "    " rogue " \\"; print }
' "$REPO/web/build.sh" > "$WORK/build_rogue.sh"
if cmp -s "$REPO/web/build.sh" "$WORK/build_rogue.sh"; then
    echo "selftest FAIL: plant 2c was a no-op — no extra TU was added to the scratch compile line"
    fails=1
else
    n_rogue=$(extract_src_tus "$WORK/build_rogue.sh" | grep -c .)
    if [ "$n_rogue" -ne "$N_LIVE_TUS" ]; then
        echo "selftest FAIL: plant 2c changed the derived inventory ($N_LIVE_TUS -> $n_rogue); it must be invisible to it, or it is not testing check_sources_only"
        fails=1
    elif check_sources_only "$WORK/build_rogue.sh" 2>"$WORK/rogue.err"; then
        echo "selftest FAIL: plant 2c (a TU on the compile line outside SOURCES) passed — the gate compiles 23 of 24"
        fails=1
    elif grep -qF "$ROGUE_TU" "$WORK/rogue.err"; then
        echo "selftest ok: plant 2c a TU on the compile line outside SOURCES is FAIL by name"
    else
        echo "selftest FAIL: plant 2c went red for the wrong reason:"
        sed 's/^/      /' "$WORK/rogue.err"
        fails=1
    fi
fi

# Plant 3: a population BELOW the floor -> examine_tus must FAIL. `> 0` alone
# cannot see a derived list that shrank from 22 to 1; this is the plant that
# makes the floor non-vacuous (mechanical-gates §43). Built from the live list
# so the TU compiles cleanly and the ONLY thing wrong is the population size.
head -1 "$WORK/live.tus" > "$WORK/short.tus"
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

# Plant 3b: the playground entry point REMOVED from the inventory. This is
# plant 3 aimed at the exact shrink that happened for real — the population
# falls from 23 to 22 and the floor must call it RED. Plant 3 uses a 1-entry
# list, which any floor > 1 catches; 3b is the off-by-one a floor of 22 would
# have waved through.
#
# It edits the EVALUATED array, not the text of web/build.sh. Round 2 deleted a
# line matching `^ *web/eigs_wasm\.c *$` and so was pinned to one-entry-per-line
# formatting: reflowing the array made the deletion a no-op and turned [99i3]
# falsely RED while the gate itself was fine. A plant must fail when the gate
# is broken, not when the subject is reindented.
grep -vx "$SHIM_TU" "$WORK/live.tus" > "$WORK/noshim.tus"
n_noshim=$(grep -c . "$WORK/noshim.tus")
if [ "$n_noshim" -ne $((N_LIVE_TUS - 1)) ]; then
    echo "selftest FAIL: plant 3b removed $((N_LIVE_TUS - n_noshim)) TU(s), not exactly 1 (live=$N_LIVE_TUS planted=$n_noshim)"
    fails=1
elif examine_tus "$WORK/noshim.tus" "" "$STUB" "$TU_FLOOR" >/dev/null 2>"$WORK/noshim.err"; then
    echo "selftest FAIL: plant 3b (the inventory minus the playground entry point, $n_noshim of $TU_FLOOR) passed — the floor cannot see the entry point leave"
    fails=1
elif grep -q "examined $n_noshim playground TUs, floor is $TU_FLOOR" "$WORK/noshim.err"; then
    echo "selftest ok: plant 3b dropping the playground entry point ($n_noshim of $TU_FLOOR) is FAIL"
else
    echo "selftest FAIL: plant 3b went red for the wrong reason:"
    sed 's/^/      /' "$WORK/noshim.err"
    fails=1
fi

# Control: REFORMATTING the array must not change the inventory. The extractor
# is the one piece of this gate that reads web/build.sh as TEXT, so it is the
# one piece a reflow can silently empty — the round-2 version skipped the
# `SOURCES=(` line whole, so a single-line array yielded ZERO entries and the
# empty-inventory rule would have reported a "shrink" that never happened.
# The scratch file collapses the whole array onto one line.
{
    printf 'SOURCES=('
    while IFS= read -r tu; do
        [ -z "$tu" ] && continue
        printf ' %s' "$tu"
    done < "$WORK/live.tus"
    printf ' )\n'
} > "$WORK/oneline.txt"
awk 'NR==FNR { repl = $0; next }
     /^SOURCES=\(/ { print repl; skip = 1; next }
     skip { if ($0 ~ /^\)/) skip = 0; next }
     { print }' "$WORK/oneline.txt" "$REPO/web/build.sh" > "$WORK/build_oneline.sh"
if cmp -s "$REPO/web/build.sh" "$WORK/build_oneline.sh"; then
    echo "selftest FAIL: the reformat control was a no-op — the scratch SOURCES array was not reflowed"
    fails=1
else
    extract_src_tus "$WORK/build_oneline.sh" > "$WORK/oneline.tus"
    if cmp -s "$WORK/live.tus" "$WORK/oneline.tus"; then
        echo "selftest ok: reformat control a one-line SOURCES array yields the identical $N_LIVE_TUS-TU inventory"
    else
        echo "selftest FAIL: reformatting SOURCES changed the derived inventory — the extractor is pinned to the current layout:"
        diff "$WORK/live.tus" "$WORK/oneline.tus" | sed 's/^/      /'
        fails=1
    fi
fi

# Control: the live inventory must still be green, or the selftest has broken
# the compile function. Re-derive from web/build.sh, same as production —
# including the floor and the compile-line audit, so the control mirrors the
# production call exactly.
extract_src_tus "$REPO/web/build.sh" > "$WORK/live.tus"
if ! check_sources_only "$REPO/web/build.sh" 2>"$WORK/live-audit.err"; then
    echo "selftest FAIL: the live compile line names a TU outside SOURCES:"
    sed 's/^/      /' "$WORK/live-audit.err"
    fails=1
elif ! examine_tus "$WORK/live.tus" "" "$STUB" "$TU_FLOOR" >/dev/null; then
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
