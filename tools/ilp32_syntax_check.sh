#!/usr/bin/env bash
# ILP32 syntax gate — the playground's wasm32 build cannot break unnoticed.
#
# pages.yml compiles the web/build.sh sources with emcc (wasm32). A
# _Static_assert that was true only at 64-bit pointer width (#1183's "union
# sized by fn") kept that lane red from bcdd99f (#1185). This gate runs the
# same recipe locally without emcc: clang -m32 -fsyntax-only over EVERY
# translation unit the recipe hands the compiler.
#
# POPULATION = THE RECORDED ARGV, NOT A READING OF THE SCRIPT. Three rounds in
# a row derived the population by TEXT matching and three rounds in a row a
# blind critic found a spelling the text missed: round 1 filtered SOURCES to
# `src/*.c` and examined 22 of 23; round 3 audited the compile line for `.c`
# tokens and still missed a single-quoted `'web/x.c'` literal, a `$(...)`
# substitution, an array entry behind a variable, `.C`/`.cc` units, and
# counted a comment line inside `SOURCES=(` as a source while calling `-o
# out.c` one too. A text parser cannot be made to agree with bash; bash can.
#
# So the gate ASKS BASH. It builds a scratch sandbox (every top-level entry of
# the repo symlinked, `web/` copied so nothing is written back into the tree),
# puts a stand-in `emcc` first on PATH that RECORDS its argv one argument per
# NUL and exits 0 without compiling (creating the `-o` target so the recipe's
# later steps still complete), runs the REAL web/build.sh there, and then
# classifies the recorded arguments: an INPUT is an argument that is not an
# option, is not an option's operand (`-o X`, `--js-library X`, `-s X=Y`,
# `--pre-js X`, ... — option_takes_operand enumerates the separated-operand
# options from emcc's documented list plus the ones this recipe uses), and
# ends in a C/C++ translation-unit suffix. Quoting, substitution, variables and
# array shape are bash's problem, and bash has already solved them by the time
# the stand-in sees argv. The assertion is examined == len(recorded inputs) > 0,
# floored; an empty inventory is FAIL, not a clean tree.
#
# Residual, stated rather than implied: an UNRECOGNISED separated-operand
# option whose operand ends in `.c` is counted as an input. That direction is
# fail-loud — the gate compiles a non-TU and goes red by name — not silent.
#
# DEFINE PARITY IS DERIVED, NOT TYPED. Round 2 defined a bare `EMSCRIPTEN` that
# emcc does not define; round 3 replaced it with three hand-typed predefines
# (`__EMSCRIPTEN__`, `__wasm__`, `__wasm32__`) and called them "the target's own
# predefines". Measured 2026-09-21: the wasm32-emscripten target predefines 354
# macros and the `-m32` host predefines 378, and they differ in 39 names — the
# hand-typed three were 3 of the 9 the target adds, and NONE of the 30 the host
# adds were removed, so `src/fsutil.c:69 #elif defined(__linux__)` took the
# Linux arm under a gate standing in for a lane that has no `__linux__` at all.
# So the gate now DERIVES both worlds with `-E -dM` (target:
# `clang --target=wasm32-unknown-emscripten`; host: `clang -m32`), reconciles
# every difference with a `-U` or a `-D` carrying the target's own value, and
# then RE-DERIVES the host world under those flags and asserts, for every macro
# tested by any `#if`/`#ifdef`/`#ifndef`/`#elif` in the examined TUs and in
# `src/*.h` + `web/*.h`, that defined-ness under the gate equals defined-ness
# under the target. It FAILS BY NAME on any tested macro it cannot reconcile.
# The report line `macro_parity: tested=N reconciled=N` is printed on every
# run, together with the macros the population actually tests that differ
# between the two worlds — DERIVED, so no comment here has to claim which
# conditionals those are. (Measured today: two, `src/fsutil.c:69` on
# `__linux__` and `src/jit.c:110` on `__wasm__`. That number is printed by the
# gate; this sentence is the reading, not the source of truth.)
#
# LIMIT, named: this is PREDEFINE parity. A macro a SYSTEM HEADER defines —
# `__GLIBC__` is the live example, tested by the population and supplied by
# glibc's features.h — is outside it, because the stand-in compiles against
# this box's headers by design and emscripten's headers are not here.
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
#   --selftest : plant, through the REAL derive/compile/examine functions,
#                (1) the old sizeof(data)==sizeof(fn) assert, (1b) a syntax
#                error in a scratch copy of the playground entry point,
#                (1c) an emcc-only #ifdef __EMSCRIPTEN__ arm, (1d) a misplaced
#                EMSCRIPTEN_KEEPALIVE, (2) an empty TU list, (3) a population
#                below the floor, (3b) the entry point dropped from the
#                inventory, and six ARGV-SHAPE plants that a text parser reads
#                wrong — (2q) a single-quoted literal on the compile line,
#                (2s) a command substitution, (2v) an array entry behind a
#                variable, (2x) a `.cc` unit, (2m) a comment line inside
#                `SOURCES=(` naming a `.c` (must NOT count), (2o) an `-o`
#                operand ending in `.c` (must NOT count) — plus (4m) an arm the
#                real target takes and the host does not, with (4mc) its
#                opposite as a control, (4e) parity verified with NO
#                reconciliation flags (must FAIL by name), (4z) an empty tested
#                population (must FAIL, not pass with 0), and two controls: a
#                REFORMATTED SOURCES array must yield the identical inventory,
#                and the live inventory must stay green.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd)

# emcc is handed -DEIGENSCRIPT_VERSION from the VERSION file (web/build.sh's
# emcc line). web/eigs_wasm.c's eigs_version() returns that macro, so the TU
# does not compile without it. Read it the same way that script does.
EIGS_VERSION=$(cat "$REPO/VERSION" 2>/dev/null || echo dev)

SELFTEST=0
[ "${1:-}" = "--selftest" ] && SELFTEST=1

# Floor on the derived population. Measured 2026-09-21: the playground recipe
# hands the compiler 23 translation units and all 23 are examined — the 22
# src/*.c runtime units plus web/eigs_wasm.c, the playground entry point on the
# same invocation. Adding a source raises the count and needs no edit; a
# DECREASE is a deliberate re-pin. Plant 3b is the case that matters: dropping
# the entry point takes the population to 22, which this floor calls RED.
TU_FLOOR="${EIGS_ILP32_TU_FLOOR:-23}"

# The reconciliation flags derived by macro_parity_init. Empty until then, so
# the availability probe (which needs no parity) runs first.
MACRO_PARITY_FLAGS=''
MACRO_PARITY_REPORT=''

# ---- scratch state --------------------------------------------------------
# STUB: the two headers this box lacks. RUN: sandboxes, recorded argv, derived
# macro sets. WORK: the selftest's own scratch. None of them is in the tree.
STUB=$(mktemp -d "${TMPDIR:-/tmp}/eigs-ilp32-stub-XXXXXX")
RUN=$(mktemp -d "${TMPDIR:-/tmp}/eigs-ilp32-run-XXXXXX")
WORK=''
trap 'rm -rf -- "${STUB:-}" "${RUN:-}" "${WORK:-}"' EXIT

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

# The recording stand-in. It lives in RUN, never in the tree, and is put FIRST
# on PATH for the recipe run — so what it records is exactly what bash expanded.
STANDIN_BIN="$RUN/standin"
mkdir -p "$STANDIN_BIN"
cat > "$STANDIN_BIN/emcc" <<'EIGS_ILP32_STANDIN'
#!/usr/bin/env bash
# Records argv one argument per NUL and exits 0 without compiling. The -o
# target is created so a recipe that copies or lists its own output completes.
printf '%s\0' "$@" > "${EIGS_ILP32_ARGV_OUT:?}"
prev=
for a in "$@"; do
    if [ "$prev" = "-o" ]; then
        mkdir -p "$(dirname "$a")" 2>/dev/null
        : > "$a" 2>/dev/null
    fi
    prev=$a
done
exit 0
EIGS_ILP32_STANDIN
chmod +x "$STANDIN_BIN/emcc"

# ---- population: what the recipe actually hands the compiler --------------

# Separated-operand options: the NEXT argument belongs to this option and is
# never an input, however it is spelled. Taken from emcc's documented option
# list (the --*-js / --*-file / -s family) and clang's, plus every option this
# recipe uses. Attached forms (-DFOO, -I/x, -sX=Y) need no entry: they start
# with `-`, so they are options by the rule below.
option_takes_operand() {
    case "$1" in
        -o|-I|-D|-U|-L|-l|-x|-T|-u|-z|-e|-include|-imacros|-isystem|-iquote) return 0 ;;
        -idirafter|-iprefix|-iwithprefix|-isysroot|-MF|-MT|-MQ|-MJ) return 0 ;;
        -Xlinker|-Xclang|-Xpreprocessor|-Xassembler|-arch|-target|--target) return 0 ;;
        -s|-install_name|-framework|--sysroot) return 0 ;;
        --js-library|--pre-js|--post-js|--extern-pre-js|--extern-post-js) return 0 ;;
        --shell-file|--embed-file|--preload-file|--exclude-file|--js-transform) return 0 ;;
        --cache|--output_eol|--output-eol|--valid-abspath|--source-map-base) return 0 ;;
        --memory-init-file|--closure|--minify|--default-obj-ext|--emit-tsd) return 0 ;;
        --llvm-opts|--llvm-lto|--use-port|--emrun|--proxy-to-worker) return 0 ;;
    esac
    return 1
}

# $1 = the NUL-separated argv file, $2 = the directory the recipe ran in.
# Prints one ABSOLUTE input path per line and nothing else — the caller owns
# every verdict.
classify_inputs() {
    local argv="$1" root="$2" arg prev=''
    while IFS= read -r -d '' arg; do
        if [ -n "$prev" ] && option_takes_operand "$prev"; then
            prev=''
            continue
        fi
        prev="$arg"
        case "$arg" in -*) continue ;; esac
        case "$arg" in
            *.c|*.C|*.cc|*.CC|*.cpp|*.CPP|*.cxx|*.CXX|*.c++) ;;
            *) continue ;;
        esac
        case "$arg" in
            /*) printf '%s\n' "$arg" ;;
            *)  printf '%s\n' "$root/$arg" ;;
        esac
    done < "$argv"
}

# $1 = sandbox dir to create, $2 = the build script to install as web/build.sh.
# Every top-level entry of the repo is SYMLINKED so the recipe sees a real
# tree; `web/` alone is COPIED, because the recipe writes web/dist/ and this
# gate must not touch the working tree. Dotfiles are not staged: no playground
# recipe reads one, and staging them would carry .git into the sandbox.
sandbox_prepare() {
    local sbx="$1" script="$2" e name
    mkdir -p "$sbx" || return 1
    for e in "$REPO"/*; do
        name=${e##*/}
        [ "$name" = web ] && continue
        ln -sfn "$e" "$sbx/$name" || return 1
    done
    cp -r "$REPO/web" "$sbx/web" || return 1
    rm -rf "$sbx/web/dist"
    cp "$script" "$sbx/web/build.sh" || return 1
    return 0
}

# $1 = a prepared sandbox, $2 = file to write the derived input list to.
# Runs the recipe with the recording stand-in first on PATH. Diagnostics on
# stderr; status is the return value.
sandbox_record_inputs() {
    local sbx="$1" out="$2" argv log rc
    argv="$sbx/.eigs-ilp32-argv"
    log="$sbx/.eigs-ilp32-recipe.log"
    rm -f "$argv"
    EIGS_ILP32_ARGV_OUT="$argv" PATH="$STANDIN_BIN:$PATH" \
        bash "$sbx/web/build.sh" > "$log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL: the playground recipe exited $rc under the recording stand-in, so the gate cannot know what is compiled:" >&2
        sed 's/^/      /' "$log" >&2
        return 1
    fi
    if ! [ -f "$argv" ]; then
        echo "FAIL: the playground recipe completed without ever invoking the compiler — there is no argv to examine, and an unexamined recipe is not a clean one" >&2
        sed 's/^/      /' "$log" >&2
        return 1
    fi
    classify_inputs "$argv" "$sbx" > "$out"
    return 0
}

# ---- define parity: derive both worlds, reconcile, then re-derive ---------

# $1 = raw -dM output file, $2 = world (target|host), rest = extra flags.
# The -Werror trio is not load-bearing for a -dM run; it is here because
# tools/werror_switch_check.sh audits every compile line in this script by
# SOURCE TEXT, and an audited line without them is a violation.
derive_predefines() {
    local raw="$1" world="$2" rc
    shift 2
    if [ "$world" = target ]; then
        clang --target=wasm32-unknown-emscripten -E -dM -x c /dev/null \
            -Werror=switch -Werror=comment -Werror=misleading-indentation \
            -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_MODEL=0 -DEIGENSCRIPT_EXT_DB=0 \
            -DEIGENSCRIPT_VERSION="\"$EIGS_VERSION\"" "$@" > "$raw" 2>"$raw.err"
        rc=$?
    else
        clang -m32 -E -dM -x c /dev/null \
            -Werror=switch -Werror=comment -Werror=misleading-indentation \
            -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_MODEL=0 -DEIGENSCRIPT_EXT_DB=0 \
            -DEIGENSCRIPT_VERSION="\"$EIGS_VERSION\"" "$@" > "$raw" 2>"$raw.err"
        rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        echo "FAIL: could not derive the $world predefines (exit $rc):" >&2
        sed 's/^/      /' "$raw.err" >&2
        return 1
    fi
    if ! [ -s "$raw" ]; then
        echo "FAIL: the $world predefine derivation produced no macros at all" >&2
        return 1
    fi
    return 0
}

# $1 = a -dM file. Prints the macro NAMES (function-like names truncated at the
# parenthesis), sorted and unique, and nothing else.
predefine_names() {
    awk '{ n = $2; sub(/\(.*/, "", n); print n }' "$1" | sort -u
}

# $1 = TU list file, $2 = output file for the tested macro names.
# Every identifier appearing in a preprocessor conditional of the examined TUs
# and of src/*.h + web/*.h — a deliberate superset of "macros that could change
# which arm is compiled". `defined` itself is not a macro.
tested_macros() {
    local list="$1" out="$2" files
    files="$RUN/parity-scan.list"
    { cat "$list"; ls "$REPO"/src/*.h "$REPO"/web/*.h 2>/dev/null; } > "$files"
    if ! [ -s "$files" ]; then
        return 1
    fi
    awk '
        /^[ \t]*#[ \t]*(if|ifdef|ifndef|elif)([ \t(!].*)?$/ {
            line = $0
            sub(/^[ \t]*#[ \t]*/, "", line)
            sub(/^(ifdef|ifndef|elif|if)[ \t]*/, "", line)
            while (match(line, /[A-Za-z_][A-Za-z0-9_]*/)) {
                w = substr(line, RSTART, RLENGTH)
                if (w != "defined") print w
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ' $(cat "$files") | sort -u > "$out"
    [ -s "$out" ]
}

# $1 = tested-names file, $2 = reconciliation flags, $3 = target names file,
# $4 = how many predefine differences those flags cover, $5 = world-macro list.
# Re-derives the HOST world UNDER the flags and asserts defined-ness parity for
# every tested macro. Sets MACRO_PARITY_REPORT. FAILS BY NAME on a mismatch.
macro_parity_verify() {
    local tested="$1" flags="$2" tnames="$3" ndiff="$4" world="$5"
    local eff="$RUN/host-eff.dM" enames="$RUN/host-eff.names"
    local m n_tested n_ok=0 bad='' in_t in_h n_world
    n_tested=$(grep -c . "$tested")
    if [ "$n_tested" -eq 0 ]; then
        echo "FAIL: macro parity tested 0 macros — an empty population is not parity, it is a gate that measured nothing" >&2
        return 1
    fi
    derive_predefines "$eff" host $flags || return 1
    predefine_names "$eff" > "$enames"
    while IFS= read -r m; do
        [ -z "$m" ] && continue
        in_t=0; grep -qx -- "$m" "$tnames" && in_t=1
        in_h=0; grep -qx -- "$m" "$enames" && in_h=1
        if [ "$in_t" -eq "$in_h" ]; then
            n_ok=$((n_ok + 1))
        else
            bad="$bad $m"
        fi
    done < "$tested"
    n_world=$(grep -c . <<<"$world")
    [ -z "$world" ] && n_world=0
    MACRO_PARITY_REPORT="macro_parity: tested=$n_tested reconciled=$n_ok ($ndiff predefine differences reconciled; $n_world tested by the population:$(tr '\n' ' ' <<<"$world" | sed 's/ *$//;s/^/ /'))"
    if [ -n "$bad" ]; then
        echo "FAIL: macro parity could not reconcile these tested macro(s) between the wasm32-emscripten target and this gate's -m32 stand-in:$bad" >&2
        echo "      A tested macro whose defined-ness differs means the gate compiles a DIFFERENT arm from the lane it stands in for." >&2
        return 1
    fi
    return 0
}

# $1 = TU list file. Derives both worlds, builds the reconciliation flags into
# MACRO_PARITY_FLAGS, and verifies. Nothing here is hand-typed: every -D and
# -U comes from the two -dM derivations.
macro_parity_init() {
    local list="$1"
    local tgt="$RUN/target.dM" hst="$RUN/host.dM"
    local tnames="$RUN/target.names" hnames="$RUN/host.names"
    local tested="$RUN/tested.names" only_h="$RUN/host-only" only_t="$RUN/target-only"
    local world="$RUN/world.names"
    local m v flags='' ndiff=0

    derive_predefines "$tgt" target || return 1
    derive_predefines "$hst" host || return 1
    predefine_names "$tgt" > "$tnames"
    predefine_names "$hst" > "$hnames"
    if ! tested_macros "$list" "$tested"; then
        echo "FAIL: no preprocessor conditional was scanned — the parity check would be vacuous" >&2
        return 1
    fi

    comm -13 "$tnames" "$hnames" > "$only_h"
    comm -23 "$tnames" "$hnames" > "$only_t"

    while IFS= read -r m; do
        [ -z "$m" ] && continue
        flags="$flags -U$m"
        ndiff=$((ndiff + 1))
    done < "$only_h"
    while IFS= read -r m; do
        [ -z "$m" ] && continue
        if grep -q "^#define $m(" "$tgt"; then
            echo "FAIL: the target predefines $m as a function-like macro; this gate cannot reconcile it with a single -D" >&2
            return 1
        fi
        v=$(awk -v M="$m" '$2 == M { sub(/^#define[ \t]+[^ \t]+[ \t]*/, ""); print; exit }' "$tgt")
        case "$v" in
            *[[:space:]]*)
                echo "FAIL: the target defines $m as '$v', which is not a single -D token; reconcile it by hand or narrow the population" >&2
                return 1
                ;;
        esac
        flags="$flags -D$m=$v"
        ndiff=$((ndiff + 1))
    done < "$only_t"

    sort -u "$only_h" "$only_t" > "$RUN/diff.names"
    comm -12 "$tested" "$RUN/diff.names" > "$world"
    MACRO_PARITY_FLAGS="$flags"
    macro_parity_verify "$tested" "$MACRO_PARITY_FLAGS" "$tnames" "$ndiff" "$(cat "$world")" || return 1
    return 0
}

# ---- compiling and examining ---------------------------------------------

# $1 = translation unit path. $2 = optional extra -I dir, prepended so a
# planted header wins. $3 = optional stub dir. Diagnostics on stderr; status is
# the return value. Do not print a verdict here — examine_tus owns the report.
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
    # $MACRO_PARITY_FLAGS is DERIVED (see macro_parity_init) — the target's
    # predefines minus the host's, computed, never typed.
    out=$(clang -m32 -fsyntax-only -c \
        -Werror=switch -Werror=comment -Werror=misleading-indentation \
        -isystem "$stubdir" -isystem /usr/include/x86_64-linux-gnu \
        $inc \
        -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_MODEL=0 -DEIGENSCRIPT_EXT_DB=0 \
        $MACRO_PARITY_FLAGS \
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
# population is DERIVED from the recorded argv, and a derived population
# shrinks silently. `> 0` catches losing ALL of them and nothing else —
# dropping 22 of 23 would still print OK. The floor turns a shrink into a
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
        echo "FAIL: examined $n playground TUs, floor is $floor — the playground recipe hands the compiler fewer sources than it did; re-pin the floor deliberately or restore the sources" >&2
        return 1
    fi
    if [ "$n_ok" -ne "$n" ]; then
        echo "FAIL: examined $n TUs, $n_ok ok, $n_fail failed (want examined == len(list) > 0)" >&2
        return 1
    fi
    echo "OK: examined $n ILP32 TUs (every input the playground recipe hands the compiler)"
    return 0
}

# ---- availability --------------------------------------------------------
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

# ---- the live population, derived once ------------------------------------
LIVE_SBX="$RUN/sbx-live"
LIVE_TUS="$RUN/live.tus"
if ! sandbox_prepare "$LIVE_SBX" "$REPO/web/build.sh"; then
    echo "FAIL: could not stage the playground recipe in a scratch sandbox" >&2
    exit 1
fi
if ! sandbox_record_inputs "$LIVE_SBX" "$LIVE_TUS"; then
    exit 1
fi
N_LIVE_TUS=$(grep -c . "$LIVE_TUS")

if ! macro_parity_init "$LIVE_TUS"; then
    exit 1
fi
echo "$MACRO_PARITY_REPORT"

if [ "$SELFTEST" -eq 0 ]; then
    examine_tus "$LIVE_TUS" "" "$STUB" "$TU_FLOOR"
    exit $?
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
entry_ok=1
if ! [ -f "$REPO/$SHIM_TU" ]; then
    echo "selftest FAIL: the entry-point plants cannot run — $SHIM_TU is not in the tree"
    fails=1
    entry_ok=0
elif ! grep -qx "$LIVE_SBX/$SHIM_TU" "$LIVE_TUS"; then
    echo "selftest FAIL: the entry-point plants cannot run — $SHIM_TU is not in the derived inventory (the gate is back to examining fewer TUs than the recipe compiles)"
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

    # 1c: an arm keyed on a macro the REAL target predefines and the -m32 host
    # does not. Under round 2's bare-name define this compiled clean while emcc
    # saw the #error; today __EMSCRIPTEN__ reaches the compile only because the
    # parity derivation put it there.
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

# ---- the argv-shape plants (2q, 2s, 2v, 2x, 2m, 2o) ----------------------
# Every one of these is a shape a TEXT parser reads wrong and bash does not.
# They run through sandbox_prepare + sandbox_record_inputs — the REAL
# derivation — and assert the count the population moved by, the presence or
# absence of the planted name, and, where a TU really is added, that
# compile_tu rejects it by the marker planted inside it.
#
# $1 key, $2 label, $3 expected delta on the population, $4 repo-relative name
# that must be PRESENT (empty = none), $5 name that must be ABSENT (empty =
# none), $6 content to write at $4 before the recipe runs (empty = none).
# The scratch recipe is read from "$WORK/$key.sh".
argv_plant() {
    local key="$1" label="$2" want_delta="$3" want_present="$4" want_absent="$5" tu_content="${6:-}"
    local sbx="$WORK/sbx-$key" list="$WORK/$key.tus" n delta
    if cmp -s "$REPO/web/build.sh" "$WORK/$key.sh"; then
        echo "selftest FAIL: $label was a no-op — the scratch recipe is identical to the live one"
        fails=1
        return
    fi
    if ! sandbox_prepare "$sbx" "$WORK/$key.sh" 2>"$WORK/$key.prep.err"; then
        echo "selftest FAIL: $label could not be staged:"
        sed 's/^/      /' "$WORK/$key.prep.err"
        fails=1
        return
    fi
    if [ -n "$tu_content" ] && [ -n "$want_present" ]; then
        mkdir -p "$(dirname "$sbx/$want_present")"
        printf '%s\n' "$tu_content" > "$sbx/$want_present"
    fi
    if ! sandbox_record_inputs "$sbx" "$list" 2>"$WORK/$key.rec.err"; then
        echo "selftest FAIL: $label — the scratch recipe recorded no argv:"
        sed 's/^/      /' "$WORK/$key.rec.err"
        fails=1
        return
    fi
    n=$(grep -c . "$list")
    delta=$((n - N_LIVE_TUS))
    if [ "$delta" -ne "$want_delta" ]; then
        echo "selftest FAIL: $label moved the population by $delta, want $want_delta (live=$N_LIVE_TUS planted=$n)"
        sed 's/^/      /' "$list"
        fails=1
        return
    fi
    if [ -n "$want_absent" ] && grep -qx "$sbx/$want_absent" "$list"; then
        echo "selftest FAIL: $label — $want_absent was counted as a translation unit; it is not one"
        fails=1
        return
    fi
    if [ -n "$want_present" ]; then
        if ! grep -qx "$sbx/$want_present" "$list"; then
            echo "selftest FAIL: $label — $want_present is compiled by the recipe and is NOT in the derived population"
            sed 's/^/      /' "$list"
            fails=1
            return
        fi
        if compile_tu "$sbx/$want_present" "" "$STUB" 2>"$WORK/$key.ex.err"; then
            echo "selftest FAIL: $label — the planted unit was examined but compiled clean, so nothing was proved"
            fails=1
            return
        fi
        if ! grep -qF "EIGS_ILP32_PLANT" "$WORK/$key.ex.err"; then
            echo "selftest FAIL: $label went red for the wrong reason:"
            sed 's/^/      /' "$WORK/$key.ex.err"
            fails=1
            return
        fi
    fi
    echo "selftest ok: $label"
}

BUILD_SH="$REPO/web/build.sh"
# Anchors are SEMANTIC text, never line offsets: the array expansion line and
# the `SOURCES=(` opening.
awk '{ print } /^[ \t]*"\$\{SOURCES\[@\]\}"[ \t]*\\[ \t]*$/ { print "    '\''web/eigs_ilp32_plant_2q.c'\'' \\" }' \
    "$BUILD_SH" > "$WORK/2q.sh"
argv_plant 2q "plant 2q a single-quoted TU literal on the compile line is examined (24 of 24)" \
    1 "web/eigs_ilp32_plant_2q.c" "" '#error EIGS_ILP32_PLANT_2Q'

awk '{ print } /^[ \t]*"\$\{SOURCES\[@\]\}"[ \t]*\\[ \t]*$/ { print "    $(echo web/eigs_ilp32_plant_2s.c) \\" }' \
    "$BUILD_SH" > "$WORK/2s.sh"
argv_plant 2s "plant 2s a command-substituted TU on the compile line is examined (24 of 24)" \
    1 "web/eigs_ilp32_plant_2s.c" "" '#error EIGS_ILP32_PLANT_2S'

awk '/^SOURCES=\(/ { print "EIGS_ILP32_PLANT_DIR=web" } { print } /^SOURCES=\(/ { print "    $EIGS_ILP32_PLANT_DIR/eigs_ilp32_plant_2v.c" }' \
    "$BUILD_SH" > "$WORK/2v.sh"
argv_plant 2v "plant 2v an array entry behind a shell variable is examined (24 of 24)" \
    1 "web/eigs_ilp32_plant_2v.c" "" '#error EIGS_ILP32_PLANT_2V'

awk '{ print } /^SOURCES=\(/ { print "    web/eigs_ilp32_plant_2x.cc" }' \
    "$BUILD_SH" > "$WORK/2x.sh"
argv_plant 2x "plant 2x a .cc translation unit is examined (24 of 24)" \
    1 "web/eigs_ilp32_plant_2x.cc" "" '#error EIGS_ILP32_PLANT_2X'

awk '{ print } /^SOURCES=\(/ { print "    # not a source: web/eigs_ilp32_plant_2m.c is only mentioned here" }' \
    "$BUILD_SH" > "$WORK/2m.sh"
argv_plant 2m "plant 2m a comment inside SOURCES naming a .c is NOT counted (23 of 23)" \
    0 "" "web/eigs_ilp32_plant_2m.c"

sed 's|-o web/dist/eigs\.js|-o web/dist/eigs_ilp32_plant_2o.c|' "$BUILD_SH" > "$WORK/2o.sh"
argv_plant 2o "plant 2o an -o operand ending in .c is NOT counted (23 of 23)" \
    0 "" "web/dist/eigs_ilp32_plant_2o.c"

# ---- define-parity plants (4m, 4mc, 4e, 4z) ------------------------------
# 4m is Fable's measured gap: an arm the real target takes and the -m32 host
# does not. Under round 3's hand-typed -D set this compiled clean.
printf '%s\n' '#if !defined(__linux__)' '#error EIGS_ILP32_PLANT_4M' '#endif' \
              'int eigs_ilp32_plant_4m(void);' > "$WORK/plant4m.c"
expect_tu_red plant4m "plant 4m an arm taken on the wasm32 target and not on the -m32 host" \
    "$WORK/plant4m.c" "EIGS_ILP32_PLANT_4M"

# 4mc is its control: the OPPOSITE arm must be GREEN, or "red" would only mean
# "this probe is always red".
printf '%s\n' '#if defined(__linux__)' '#error EIGS_ILP32_PLANT_4MC' '#endif' \
              'int eigs_ilp32_plant_4mc(void);' > "$WORK/plant4mc.c"
if compile_tu "$WORK/plant4mc.c" "" "$STUB" 2>"$WORK/plant4mc.err"; then
    echo "selftest ok: control 4mc the host-only arm is NOT taken under the gate's derived macro world"
else
    echo "selftest FAIL: control 4mc — the gate still takes the host's __linux__ arm:"
    sed 's/^/      /' "$WORK/plant4mc.err"
    fails=1
fi

# 4e: the VERIFICATION half, run with NO reconciliation flags. It must fail by
# name, or the derivation could be gutted and the check would still print OK.
if macro_parity_verify "$RUN/tested.names" "" "$RUN/target.names" 0 "" \
        >/dev/null 2>"$WORK/plant4e.err"; then
    echo "selftest FAIL: plant 4e (parity verified with no reconciliation flags) passed — the parity assertion is vacuous"
    fails=1
elif grep -q 'could not reconcile' "$WORK/plant4e.err"; then
    echo "selftest ok: plant 4e parity with no reconciliation flags is FAIL by name ($(sed -n 's/.*stand-in://p' "$WORK/plant4e.err" | tr -s ' '))"
else
    echo "selftest FAIL: plant 4e went red for the wrong reason:"
    sed 's/^/      /' "$WORK/plant4e.err"
    fails=1
fi

# 4z: an empty tested population must FAIL, not pass with 0 tested — the same
# rule as plant 2, applied to the macro class.
: > "$WORK/empty.macros"
if macro_parity_verify "$WORK/empty.macros" "$MACRO_PARITY_FLAGS" "$RUN/target.names" 0 "" \
        >/dev/null 2>"$WORK/plant4z.err"; then
    echo "selftest FAIL: plant 4z (an empty tested-macro population) passed — a class that measured nothing is not parity"
    fails=1
elif grep -q 'tested 0 macros' "$WORK/plant4z.err"; then
    echo "selftest ok: plant 4z an empty tested-macro population is FAIL (not PASS with 0 tested)"
else
    echo "selftest FAIL: plant 4z went red for the wrong reason:"
    sed 's/^/      /' "$WORK/plant4z.err"
    fails=1
fi

# The parity flags were clobbered by plant 4e's verify call only through its
# own locals, but re-derive anyway so the remaining plants run on the live
# world rather than on whatever the last plant left behind.
if ! macro_parity_init "$LIVE_TUS" >/dev/null 2>"$WORK/reinit.err"; then
    echo "selftest FAIL: the live macro parity stopped deriving after the plants:"
    sed 's/^/      /' "$WORK/reinit.err"
    fails=1
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
# cannot see a derived list that shrank from 23 to 1; this is the plant that
# makes the floor non-vacuous (mechanical-gates §43). Built from the live list
# so the TU compiles cleanly and the ONLY thing wrong is the population size.
head -1 "$LIVE_TUS" > "$WORK/short.tus"
if ! [ -s "$WORK/short.tus" ]; then
    echo "selftest FAIL: plant 3 could not build a 1-entry TU list from the recorded argv"
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
# have waved through. It edits the EVALUATED inventory, not any script text.
grep -vx "$LIVE_SBX/$SHIM_TU" "$LIVE_TUS" > "$WORK/noshim.tus"
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

# Control: REFORMATTING the array must not change the inventory. The round-2
# extractor read the array as TEXT and a one-line array yielded ZERO entries;
# the derivation is bash's now, so this control should be trivially true — and
# a control that is trivially true is exactly what pins the change.
{
    printf 'SOURCES=('
    while IFS= read -r tu; do
        [ -z "$tu" ] && continue
        printf ' %s' "${tu#"$LIVE_SBX/"}"
    done < "$LIVE_TUS"
    printf ' )\n'
} > "$WORK/oneline.txt"
awk 'NR==FNR { repl = $0; next }
     /^SOURCES=\(/ { print repl; skip = 1; next }
     skip { if ($0 ~ /^\)/) skip = 0; next }
     { print }' "$WORK/oneline.txt" "$BUILD_SH" > "$WORK/oneline.sh"
if cmp -s "$BUILD_SH" "$WORK/oneline.sh"; then
    echo "selftest FAIL: the reformat control was a no-op — the scratch SOURCES array was not reflowed"
    fails=1
else
    ONELINE_SBX="$WORK/sbx-oneline"
    if ! sandbox_prepare "$ONELINE_SBX" "$WORK/oneline.sh" 2>"$WORK/oneline.prep.err" \
       || ! sandbox_record_inputs "$ONELINE_SBX" "$WORK/oneline.tus" 2>"$WORK/oneline.rec.err"; then
        echo "selftest FAIL: the reformat control could not be recorded:"
        sed 's/^/      /' "$WORK/oneline.prep.err" "$WORK/oneline.rec.err" 2>/dev/null
        fails=1
    else
        sed "s|^$LIVE_SBX/||" "$LIVE_TUS" > "$WORK/live.rel"
        sed "s|^$ONELINE_SBX/||" "$WORK/oneline.tus" > "$WORK/oneline.rel"
        if cmp -s "$WORK/live.rel" "$WORK/oneline.rel"; then
            echo "selftest ok: reformat control a one-line SOURCES array yields the identical $N_LIVE_TUS-TU inventory"
        else
            echo "selftest FAIL: reformatting SOURCES changed the derived inventory:"
            diff "$WORK/live.rel" "$WORK/oneline.rel" | sed 's/^/      /'
            fails=1
        fi
    fi
fi

# Control: the live inventory must still be green, or the selftest has broken
# the compile function. Re-derive from the recipe, same as production.
LIVE2_SBX="$RUN/sbx-live2"
if ! sandbox_prepare "$LIVE2_SBX" "$BUILD_SH" 2>"$WORK/live2.prep.err" \
   || ! sandbox_record_inputs "$LIVE2_SBX" "$WORK/live2.tus" 2>"$WORK/live2.rec.err"; then
    echo "selftest FAIL: the live recipe stopped recording an argv after the plants:"
    sed 's/^/      /' "$WORK/live2.prep.err" "$WORK/live2.rec.err" 2>/dev/null
    fails=1
elif ! examine_tus "$WORK/live2.tus" "" "$STUB" "$TU_FLOOR" >/dev/null; then
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
