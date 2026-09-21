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
# So the gate ASKS BASH. It stages a scratch sandbox, puts a stand-in `emcc`
# first on PATH that RECORDS its argv one argument per NUL, its cwd, the files
# it itself created and any translation unit handed to it on STDIN, then exits
# 0 without compiling, and runs the REAL web/build.sh there. Quoting,
# substitution, variables and array shape are bash's problem, and bash has
# already solved them by the time the stand-in sees argv.
#
# CLASSIFICATION IS BY FILESYSTEM, NOT BY A TYPED GRAMMAR. Round 4 recorded
# argv and then classified it with `option_takes_operand`, a hand-typed model
# of emcc's option grammar — and the model was wrong in the direction that
# HIDES inputs. `--emrun`, `--proxy-to-worker` and `--default-obj-ext` take NO
# operand in emcc (cmdline.py's check_flag and LEGACY_FLAGS), so a translation
# unit sitting after one of them was dropped from the population while emcc
# compiled it, and the gate printed `OK: examined 23`. Response files (`@file`,
# which emcc expands before it parses anything) and `-x c <unit>` were
# uncounted for the same reason: a typed grammar drifts from the parser it
# models. There is no operand model in this file any more. Instead:
#
#   1. `@file` is EXPANDED first, as emcc expands it. Two levels are expanded;
#      a third is FAIL BY NAME, never a silently truncated population.
#   2. An INPUT is any token that NAMES AN EXISTING REGULAR FILE under the
#      sandbox (relative to the cwd the stand-in recorded) that the compiler
#      did not itself write, whose suffix is a C-family TU suffix. The rule is
#      position-independent: no argument's meaning depends on the one before
#      it. An existing file with a non-C suffix is not an input; a `.c` name
#      that does not exist is not an input; an `-o` target is not an input
#      because the stand-in recorded creating it.
#   3. The two shapes a suffix cannot see — a unit on stdin (`-x c -`) and a
#      unit whose suffix is not a TU suffix (`-x c web/unit.inc`) — are decided
#      by asking the REAL DRIVER: clang is handed the recorded argv with emcc's
#      own options removed and its `-x <lang> <file>` cc1 inputs are read back.
#      The emcc-only filter is measured, not typed: a token is emcc's exactly
#      when `clang -m32 -fsyntax-only -### <token> /dev/null` rejects it as an
#      unknown option (cached per token, per run).
#
# The two derivations are INDEPENDENT and both are reported on the
# `classifier:` line. The gate examines their UNION — so a unit either one
# finds is compiled — and a DISAGREEMENT is FAIL BY NAME in both directions,
# because a rule that is wrong here may be wrong the other way next time.
#
# Residual, stated rather than implied: the operand of an emcc-only option is
# left on the line for the driver cross-check, so `--embed-file web/data.c`
# (a DATA file that happens to be named `.c` and does exist) is counted by both
# derivations and the gate goes red by name on it. That direction is fail-loud,
# not silent; self-test control 2e pins it as such.
#
# NOTHING THE RECIPE WRITES REACHES THE TREE. Round 4 symlinked every top-level
# entry, which protected `web/` and nothing else: a recipe line writing
# `src/x.h` wrote straight through the symlink into the real src/, while the
# header claimed "nothing is written back into the tree". The gate now makes
# ONE pristine copy of the repo (measured 2026-09-21: 21 MB, 1.9 s), makes its
# FILES read-only, and hard-links a clone of it per sandbox (0.4 s). A recipe
# that creates a file succeeds and the file lands in the sandbox; a recipe that
# overwrites an existing one gets EPERM, which is loud. Plant 2w is that case.
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
# VALUE PARITY, not only defined-ness. Round 4 reconciled NAMES. 32 predefines
# are defined in both worlds with DIFFERENT values — `__SIZEOF_LONG_DOUBLE__`
# is 16 on the target and 12 on the -m32 host, `__INTPTR_TYPE__` is `long int`
# vs `int`, `__SIZE_TYPE__`, the whole `__LDBL_*` family — so
# `#if __SIZEOF_LONG_DOUBLE__ == 16` was RED on the real target and green under
# a gate printing `reconciled=48`. Each of those now gets `-U name -D name=<the
# target's value>` as well. A type macro can contradict glibc's own typedefs
# under -m32, so WHICH ones survive is MEASURED, never assumed: the gate builds
# a probe from the system headers the population itself includes and compiles
# it under the candidate set, naming (by bisection) any reconciliation glibc
# refuses. Those names are printed as `value_parity_unreconciled=` every run,
# and a conditional that READS one of them is FAIL BY NAME. The report line
# says `reconciled=` for defined-ness and `values=N/M` for values, separately:
# round 4 said "reconciled" of 48 macros while not one value had been compared.
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
#   --selftest : plant 36 faults through the REAL derive/record/classify/
#                compile/examine functions, and require each one RED for its
#                own stated reason:
#                  source faults   (1) the old sizeof(data)==sizeof(fn) assert,
#                    (1b) a syntax error in the playground entry point,
#                    (1c) an emcc-only #ifdef __EMSCRIPTEN__ arm,
#                    (1d) a misplaced EMSCRIPTEN_KEEPALIVE;
#                  argv SHAPES a text parser reads wrong  (2q) a single-quoted
#                    literal, (2s) a command substitution, (2v) an array entry
#                    behind a variable, (2x) a `.cc` unit, (2m) a comment line
#                    inside `SOURCES=(` naming a `.c` (must NOT count), (2o) an
#                    `-o` operand ending in `.c` (must NOT count);
#                  OPTION-GRAMMAR shapes round 4's typed model read wrong
#                    (2f) a TU after `--emrun`, (2p) a TU after
#                    `--proxy-to-worker`, (2r) a TU named only inside an
#                    `@response-file`, (2n) response files nested three deep
#                    (must FAIL by name), (2i) a TU on standard input,
#                    (2u) a `-x c` unit with a non-TU suffix (examined, and the
#                    suffix rule's disagreement named), (2e) the over-inclusion
#                    control: a DATA file named `.c` behind `--embed-file` is
#                    counted and red BY NAME;
#                  sandbox  (2w) a recipe line writing `src/` lands in the
#                    sandbox and NOT in the working tree;
#                  macro parity  (4m) an arm the real target takes and the host
#                    does not, with (4mc) its opposite as a control, (4e)
#                    parity verified with NO reconciliation flags, (4z) an
#                    empty tested population, (4v) a conditional comparing a
#                    predefine whose VALUE differs, with (4vc) its opposite as
#                    a control, (4w) a value reconciliation glibc's headers
#                    refuse (must be measured and named), (4y) an
#                    unreconcilable value that a conditional READS (must FAIL
#                    by name), (2t) a TU path with a space (must not shrink the
#                    tested-macro population);
#                  population size  (2) an empty TU list, (3) a population
#                    below the floor, (3b) the entry point dropped from the
#                    inventory;
#                  availability  (5s) a toolchain with no 32-bit C library must
#                    be reported UNAVAILABLE, with (5sc) the live toolchain as
#                    its control; (5r) a C library that refuses the target's
#                    macro world must produce a SKIP reason by name, with
#                    (5rc) the live toolchain as its control;
#                  controls  a REFORMATTED SOURCES array must yield the
#                    identical inventory, and the live inventory must stay
#                    green after every plant.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO=$(pwd)

# Byte collation everywhere. sort/comm/join in this file compare the SAME
# name sets three ways (set difference, set intersection, a keyed join); a
# locale that ignores punctuation orders `__DBL_MAX__` differently for `sort`
# than for `join -t TAB -k1,1` and the join silently drops rows.
export LC_ALL=C

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
# the availability probe (which needs no parity) runs first. An ARRAY, not a
# string: the target defines `__SIZE_TYPE__` as `long unsigned int`, and a
# word-split string cannot carry a -D whose value contains spaces.
MACRO_PARITY_FLAGS=()
# The defined-ness half alone, kept so the self-test can measure the value half
# against the same base the live run uses.
MACRO_PARITY_NAME_FLAGS=()
MACRO_PARITY_REPORT=''
# Value-parity state, all DERIVED each run by macro_parity_init.
VALUE_DIFF_N=0
VALUE_RECONCILED_N=0
VALUE_UNRECONCILED=''

# Classifier state, set by sandbox_record_inputs: the size of each of the two
# independent derivations, and the file naming their disagreement (empty file
# = they agree). The CALLER owns the verdict on that file.
CLASSIFIER_N_FS=0
CLASSIFIER_N_DRV=0
CLASSIFIER_DIFF_FILE=''
# path<TAB>language for every input the driver derivation reported, so a unit
# whose suffix is not a TU suffix (`-x c web/unit.inc`) is compiled AS the
# driver compiles it instead of being handed to clang suffix-first.
TU_LANG_MAP=''
# Cross-counts for the conditional scan (see tested_macros).
TESTED_CONDITIONAL_LINES=0
TESTED_SCAN_FILES=0
# The derived system-header probe used to measure which value reconciliations
# the host's own headers refuse. Built once per process.
HEADER_PROBE=''
# Set by macro_parity_init when this toolchain's C library cannot be
# preprocessed at 32 bits in the TARGET's macro world at all. That is a
# capability absence, not a fault in the tree, so the caller turns it into a
# SKIP — see the availability section for why it is an arm of the probe and
# not a FAIL.
MACRO_PARITY_SKIP_REASON=''

# ---- scratch state --------------------------------------------------------
# STUB: the two headers this box lacks. RUN: sandboxes, recorded argv, derived
# macro sets. WORK: the selftest's own scratch. None of them is in the tree.
STUB=$(mktemp -d "${TMPDIR:-/tmp}/eigs-ilp32-stub-XXXXXX")
RUN=$(mktemp -d "${TMPDIR:-/tmp}/eigs-ilp32-run-XXXXXX")
TU_LANG_MAP="$RUN/tu.lang"
: > "$TU_LANG_MAP"
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
#
# It records four FILESYSTEM facts, never a reading of emcc's option grammar:
#   argv     one argument per NUL;
#   cwd      the directory the recipe was in when it invoked the compiler, so
#            every relative argument resolves the way the compiler resolved it
#            (a recipe that `cd`s elsewhere no longer needs the gate to guess);
#   created  every file the stand-in itself WROTE. It writes the `-o` target so
#            a recipe that copies or lists its own output completes; that is
#            the stand-in's compiler role, not the classifier's. What the
#            classifier takes from it is a fact no suffix can give: a file the
#            COMPILER produced is an output, never an input;
#   stdin    the translation unit on standard input, captured only when `-` is
#            actually in argv, so a recipe that redirects nothing never blocks.
STANDIN_BIN="$RUN/standin"
mkdir -p "$STANDIN_BIN"
cat > "$STANDIN_BIN/emcc" <<'EIGS_ILP32_STANDIN'
#!/usr/bin/env bash
printf '%s\0' "$@" > "${EIGS_ILP32_ARGV_OUT:?}"
printf '%s\n' "$PWD" > "${EIGS_ILP32_CWD_OUT:?}"
: > "${EIGS_ILP32_CREATED_OUT:?}"
prev=
for a in "$@"; do
    if [ "$prev" = "-o" ]; then
        mkdir -p "$(dirname "$a")" 2>/dev/null
        if : > "$a" 2>/dev/null; then
            p=$a
            case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
            printf '%s\n' "$p" >> "${EIGS_ILP32_CREATED_OUT}"
        fi
    fi
    prev=$a
done
for a in "$@"; do
    if [ "$a" = "-" ]; then
        cat > "${EIGS_ILP32_STDIN_OUT:?}"
        break
    fi
done
exit 0
EIGS_ILP32_STANDIN
chmod +x "$STANDIN_BIN/emcc"

# ---- population: what the recipe actually hands the compiler --------------

# RESPONSE FILES ARE EXPANDED FIRST, because emcc expands them first
# (emcc.py's substitute_response_files runs before any option is parsed). An
# `@file` token is a whole compile line the gate would otherwise never see.
# $1 = a response file. Prints its tokens one per NUL and nothing else.
# `xargs` is the tokenizer on purpose: it implements the same whitespace and
# quote rules a response file uses, and it FAILS LOUDLY on an unmatched quote
# instead of silently producing one wrong token.
response_tokens() {
    xargs printf '%s\0' < "$1"
}

# $1 = NUL-separated argv in, $2 = the recipe's cwd, $3 = NUL-separated out.
# Two expansion passes (a response file, and a response file it names). A
# THIRD level is FAIL BY NAME, never a silent truncation.
expand_response_files() {
    local in="$1" root="$2" out="$3"
    local pass cur next tok path
    cur="$in"
    for pass in 1 2; do
        next="$RUN/argv.expanded.$pass"
        : > "$next"
        while IFS= read -r -d '' tok; do
            case "$tok" in
                @?*)
                    path=${tok#@}
                    case "$path" in /*) ;; *) path="$root/$path" ;; esac
                    if ! [ -f "$path" ]; then
                        echo "FAIL: the recipe handed the compiler the response file '$tok', which does not exist under the sandbox — the gate cannot know which translation units it names" >&2
                        return 1
                    fi
                    if ! response_tokens "$path" >> "$next" 2>"$RUN/rsp.err"; then
                        echo "FAIL: the response file '$tok' could not be tokenised:" >&2
                        sed 's/^/      /' "$RUN/rsp.err" >&2
                        return 1
                    fi
                    ;;
                *) printf '%s\0' "$tok" >> "$next" ;;
            esac
        done < "$cur"
        cur="$next"
    done
    while IFS= read -r -d '' tok; do
        case "$tok" in
            @?*)
                echo "FAIL: response files nest more than two deep (still unexpanded after two passes: $tok) — the gate refuses to examine a population it only partly expanded" >&2
                return 1
                ;;
        esac
    done < "$cur"
    cp "$cur" "$out"
}

# ---- classification: the FILESYSTEM decides, not a typed grammar ----------
#
# Round 4 classified argv with option_takes_operand, a hand-typed model of
# emcc's option grammar. It was wrong in the direction that HIDES inputs:
# `--emrun`, `--proxy-to-worker` and `--default-obj-ext` take NO operand in
# emcc (cmdline.py's check_flag / LEGACY_FLAGS), so a translation unit sitting
# after one of them was dropped from the population while emcc compiled it,
# and the gate printed OK. A typed grammar drifts; there is no operand model
# here any more.
#
# $1 = expanded NUL-separated argv, $2 = the recipe's cwd, $3 = the file of
# paths the stand-in CREATED, $4 = the captured stdin TU ('' if none).
# Prints one ABSOLUTE input path per line and nothing else — the caller owns
# every verdict. The rule is position-independent: a token is an input when it
# NAMES AN EXISTING REGULAR FILE that the compiler did not itself write and
# whose suffix is a C-family translation unit. An existing file with a non-C
# suffix is not an input; a `.c` name that does not exist is not an input.
classify_inputs() {
    local argv="$1" root="$2" created="$3" stdin_tu="$4" tok path
    while IFS= read -r -d '' tok; do
        if [ "$tok" = "-" ]; then
            [ -n "$stdin_tu" ] && printf '%s\n' "$stdin_tu"
            continue
        fi
        case "$tok" in
            /*) path="$tok" ;;
            *)  path="$root/$tok" ;;
        esac
        [ -f "$path" ] || continue
        grep -qxF -- "$path" "$created" && continue
        case "$tok" in
            *.c|*.C|*.cc|*.CC|*.cpp|*.CPP|*.cxx|*.CXX|*.c++) printf '%s\n' "$path" ;;
        esac
    done < "$argv"
}

# ---- the second derivation: ask the real driver --------------------------
#
# The suffix rule cannot see two shapes emcc compiles: a unit on stdin (`-x c
# -`) and a unit whose suffix is not a TU suffix (`-x c web/unit.inc`). Both
# are decided by the DRIVER, so the gate asks one: clang is handed the recorded
# argv with emcc's own options removed, and its `-x <lang> <file>` cc1 inputs
# are read back.
#
# The emcc-only filter is not a typed list either. A token is emcc's, not
# clang's, exactly when the clang driver REJECTS it as an unknown option —
# measured once per token, cached. The operand of a removed emcc option stays
# on the line; if it happens to be an existing `.c` file, BOTH derivations
# count it and the gate goes red by name on it. That over-inclusion is
# fail-loud and stated, not silent.
# The cache is two NUL-delimited FILES, not an associative array: macOS ships
# bash 3.2, which has no `declare -A` (and no `mapfile`), and this gate has to
# at least reach its own availability probe on that runner.
# $1 = cache file, $2 = token. Status 0 = present.
option_cache_has() {
    local f="$1" t="$2" e
    [ -s "$f" ] || return 1
    while IFS= read -r -d '' e; do
        [ "$e" = "$t" ] && return 0
    done < "$f"
    return 1
}

# $1 = an argv token. Status 0 = the real driver rejects it as unknown.
driver_rejects_option() {
    local tok="$1" out
    option_cache_has "$RUN/opt.unknown" "$tok" && return 0
    option_cache_has "$RUN/opt.known" "$tok" && return 1
    # A real compile invocation by tools/werror_switch_check.sh's recognizer
    # (it carries -c), so it carries the required -Werror trio like every other
    # compile line in this file. -### stops before any work is done.
    out=$(clang -m32 -fsyntax-only -c \
        -Werror=switch -Werror=comment -Werror=misleading-indentation \
        -### "$tok" /dev/null 2>&1)
    if grep -qE "unknown argument|unsupported option|unknown [a-z]+ argument" <<<"$out"; then
        printf '%s\0' "$tok" >> "$RUN/opt.unknown"
        return 0
    fi
    printf '%s\0' "$tok" >> "$RUN/opt.known"
    return 1
}

# $1 = expanded argv, $2 = cwd, $3 = captured stdin TU, $4 = output list.
# Prints nothing on stdout; writes one ABSOLUTE path per line to $4.
driver_inputs() {
    local argv="$1" root="$2" stdin_tu="$3" out="$4"
    local tok lang file rc
    local -a keep=()
    while IFS= read -r -d '' tok; do
        case "$tok" in
            -?*) driver_rejects_option "$tok" && continue ;;
        esac
        keep+=("$tok")
    done < "$argv"
    ( cd "$root" && clang -m32 -fsyntax-only -c \
        -Werror=switch -Werror=comment -Werror=misleading-indentation \
        -### "${keep[@]}" ) >/dev/null 2>"$RUN/driver.err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL: the real compiler driver refused the recorded command line (exit $rc), so the gate cannot cross-check which arguments are translation units:" >&2
        sed 's/^/      /' "$RUN/driver.err" >&2
        return 1
    fi
    : > "$out"
    : > "$TU_LANG_MAP"
    while IFS= read -r line; do
        lang=${line#\"-x\" \"}
        lang=${lang%%\"*}
        file=${line##*\" \"}
        file=${file%\"}
        case "$lang" in c|c-header|c++|c++-header|cpp-output|c++-cpp-output|objective-c|objective-c++) ;; *) continue ;; esac
        if [ "$file" = "-" ]; then
            [ -n "$stdin_tu" ] && { printf '%s\n' "$stdin_tu" >> "$out"; printf '%s\t%s\n' "$stdin_tu" "$lang" >> "$TU_LANG_MAP"; }
            continue
        fi
        case "$file" in
            /*) ;;
            *)  file="$root/$file" ;;
        esac
        printf '%s\n' "$file" >> "$out"
        printf '%s\t%s\n' "$file" "$lang" >> "$TU_LANG_MAP"
    done < <(grep -o '"-x" "[^"]*" "[^"]*"' "$RUN/driver.err")
    return 0
}

# $1 = a translation unit path. Prints the language to compile it AS. A
# C-family suffix speaks for itself; anything else was put in the population
# by the driver derivation, which recorded the language the driver chose.
tu_language() {
    local tu="$1" lang
    case "$tu" in
        *.c|*.C|*.cc|*.CC|*.cpp|*.CPP|*.cxx|*.CXX|*.c++) printf '' ; return 0 ;;
    esac
    lang=$(awk -F'\t' -v T="$tu" '$1 == T { print $2; exit }' "$TU_LANG_MAP" 2>/dev/null)
    printf '%s' "${lang:-c}"
}

# ---- the sandbox: nothing the recipe writes reaches the tree --------------
#
# Round 4 SYMLINKED every top-level entry, which protected `web/` and nothing
# else: a recipe line writing `src/x.h` wrote straight through the symlink into
# the real src/ (measured by a blind critic, 2026-09-21). The header claimed
# "nothing is written back into the tree", which was a wider claim than the
# mechanism.
#
# So the gate makes ONE pristine copy of the repo (measured 2026-09-21: 21 MB,
# 1.9 s) whose FILES are then made read-only, and gives each sandbox a
# hard-linked clone of it (0.4 s). Directories in the clone are fresh and
# writable, so a recipe that CREATES a file succeeds and the file lands in the
# sandbox; a recipe that OVERWRITES an existing file gets EPERM, which is loud.
# Either way the working tree is not reachable from the sandbox at all.
# `web/` is still a real copy, because the recipe writes web/dist into it.
# Dotfiles are not staged: no playground recipe reads one, and staging them
# would carry .git into the sandbox.
TREE_RO=''
tree_ro_init() {
    local e name
    [ -n "$TREE_RO" ] && return 0
    TREE_RO="$RUN/tree-ro"
    mkdir -p "$TREE_RO" || return 1
    for e in "$REPO"/*; do
        name=${e##*/}
        [ "$name" = web ] && continue
        cp -a "$e" "$TREE_RO/$name" || return 1
    done
    find "$TREE_RO" -type f -exec chmod a-w {} + || return 1
    return 0
}

# $1 = sandbox dir to create, $2 = the build script to install as web/build.sh.
sandbox_prepare() {
    local sbx="$1" script="$2" e
    tree_ro_init || return 1
    mkdir -p "$sbx" || return 1
    for e in "$TREE_RO"/*; do
        cp -al "$e" "$sbx/${e##*/}" || return 1
    done
    cp -r "$REPO/web" "$sbx/web" || return 1
    rm -rf "$sbx/web/dist"
    cp "$script" "$sbx/web/build.sh" || return 1
    chmod u+w "$sbx/web/build.sh" || return 1
    return 0
}

# $1 = a prepared sandbox, $2 = file to write the derived input list to.
# Runs the recipe with the recording stand-in first on PATH, then derives the
# population TWICE — once from the filesystem, once from the clang driver —
# and writes their UNION to $2. Any disagreement is written, by name and in
# both directions, to $sbx/.eigs-ilp32-classifier-diff; the CALLER owns that
# verdict, so a self-test can plant a disagreement and require it.
# Diagnostics on stderr; status is the return value.
sandbox_record_inputs() {
    local sbx="$1" out="$2" argv cwdf createdf stdinf log rc root stdin_tu exp
    argv="$sbx/.eigs-ilp32-argv"
    cwdf="$sbx/.eigs-ilp32-cwd"
    createdf="$sbx/.eigs-ilp32-created"
    stdinf="$sbx/.eigs-ilp32-stdin.c"
    exp="$sbx/.eigs-ilp32-argv-expanded"
    log="$sbx/.eigs-ilp32-recipe.log"
    rm -f "$argv" "$cwdf" "$createdf" "$stdinf" "$exp"
    : > "$sbx/.eigs-ilp32-classifier-diff"
    EIGS_ILP32_ARGV_OUT="$argv" EIGS_ILP32_CWD_OUT="$cwdf" \
        EIGS_ILP32_CREATED_OUT="$createdf" EIGS_ILP32_STDIN_OUT="$stdinf" \
        PATH="$STANDIN_BIN:$PATH" \
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
    root=$(cat "$cwdf" 2>/dev/null)
    [ -n "$root" ] || root="$sbx"
    expand_response_files "$argv" "$root" "$exp" || return 1
    stdin_tu=''
    [ -s "$stdinf" ] && stdin_tu="$stdinf"
    local stdin_asked=0 t
    while IFS= read -r -d '' t; do
        [ "$t" = "-" ] && stdin_asked=1
    done < "$exp"
    if [ -z "$stdin_tu" ] && [ "$stdin_asked" -eq 1 ]; then
        echo "FAIL: the recipe handed the compiler a translation unit on standard input and nothing was captured — the gate would examine one TU fewer than emcc compiles" >&2
        return 1
    fi
    classify_inputs "$exp" "$root" "$createdf" "$stdin_tu" | sort -u > "$RUN/fs.inputs"
    driver_inputs "$exp" "$root" "$stdin_tu" "$RUN/drv.raw" || return 1
    sort -u "$RUN/drv.raw" > "$RUN/drv.inputs"
    sort -u "$RUN/fs.inputs" "$RUN/drv.inputs" > "$out"
    CLASSIFIER_N_FS=$(grep -c . "$RUN/fs.inputs")
    CLASSIFIER_N_DRV=$(grep -c . "$RUN/drv.inputs")
    {
        comm -23 "$RUN/fs.inputs" "$RUN/drv.inputs" | sed 's/^/      only the suffix+filesystem rule: /'
        comm -13 "$RUN/fs.inputs" "$RUN/drv.inputs" | sed 's/^/      only the driver derivation:       /'
    } > "$sbx/.eigs-ilp32-classifier-diff"
    CLASSIFIER_DIFF_FILE="$sbx/.eigs-ilp32-classifier-diff"
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

# $1 = a -dM file. Prints `name<TAB>expansion`, sorted by name, for every
# OBJECT-like macro (a function-like macro has no single value to compare).
macro_value_map() {
    awk '{
        n = $2
        if (n ~ /\(/) next
        v = $0
        sub(/^#define[ \t]+[^ \t]+[ \t]*/, "", v)
        print n "\t" v
    }' "$1" | sort -t "$(printf '\t')" -k1,1
}

# $1 = TU list file, $2 = output file for the tested macro names.
# Every identifier appearing in a preprocessor conditional of the examined TUs
# and of src/*.h + web/*.h — a deliberate superset of "macros that could change
# which arm is compiled". `defined` itself is not a macro.
#
# THE POPULATION MUST NOT SHRINK SILENTLY. Round 4 ran `awk … $(cat "$files")`
# unquoted with no status check: one TU path containing a space made awk fail
# on that file and `tested=48` became `tested=19`, rc 0, the only sign an awk
# line on stderr (measured by a blind critic, 2026-09-21). So the file list is
# read NUL-safely into an array, awk's status is checked, awk reports how many
# files it actually opened and how many conditional lines it matched, and BOTH
# are cross-checked against an independent `grep -c` over the same list. A
# disagreement is FAIL BY NAME.
tested_macros() {
    local list="$1" out="$2" files nfiles nseen nlines ngrep
    files="$RUN/parity-scan.list"
    { cat "$list"; ls "$REPO"/src/*.h "$REPO"/web/*.h 2>/dev/null; } | tr '\n' '\0' > "$files"
    local -a scan=()
    local f
    while IFS= read -r -d '' f; do scan+=("$f"); done < "$files"
    nfiles=${#scan[@]}
    if [ "$nfiles" -eq 0 ]; then
        echo "FAIL: the parity scan enumerated no files at all" >&2
        return 1
    fi
    awk '
        FNR == 1 { nfiles++ }
        /^[ \t]*#[ \t]*(if|ifdef|ifndef|elif)([ \t(!].*)?$/ {
            nlines++
            line = $0
            sub(/^[ \t]*#[ \t]*/, "", line)
            sub(/^(ifdef|ifndef|elif|if)[ \t]*/, "", line)
            while (match(line, /[A-Za-z_][A-Za-z0-9_]*/)) {
                w = substr(line, RSTART, RLENGTH)
                if (w != "defined") print w > "/dev/stdout"
                line = substr(line, RSTART + RLENGTH)
            }
        }
        END { print nfiles + 0 " " nlines + 0 > "/dev/stderr" }
    ' "${scan[@]}" 2>"$RUN/tested.counts" | sort -u > "$out"
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        echo "FAIL: the preprocessor-conditional scan exited non-zero, so the tested-macro population is a partial one:" >&2
        sed 's/^/      /' "$RUN/tested.counts" >&2
        return 1
    fi
    nseen=$(awk 'END { print $1 + 0 }' "$RUN/tested.counts")
    nlines=$(awk 'END { print $2 + 0 }' "$RUN/tested.counts")
    if [ "$nseen" -ne "$nfiles" ]; then
        echo "FAIL: the conditional scan opened $nseen of the $nfiles files it enumerated — the tested-macro population shrank silently" >&2
        return 1
    fi
    ngrep=$(grep -chE '^[ \t]*#[ \t]*(if|ifdef|ifndef|elif)([ \t(!].*)?$' "${scan[@]}" | awk '{ s += $1 } END { print s + 0 }')
    if [ "$nlines" -ne "$ngrep" ]; then
        echo "FAIL: the conditional scan matched $nlines conditional line(s) and an independent grep over the same $nfiles files found $ngrep — the two enumerations disagree, so the tested-macro count cannot be trusted" >&2
        return 1
    fi
    TESTED_CONDITIONAL_LINES=$nlines
    TESTED_SCAN_FILES=$nfiles
    [ -s "$out" ]
}

# ---- value parity: same name, different VALUE ----------------------------
#
# Round 4 reconciled DEFINED-NESS only. 32 predefines are defined in both
# worlds with different values — `__SIZEOF_LONG_DOUBLE__` is 16 on the target
# and 12 on the -m32 host, `__INTPTR_TYPE__` is `long int` vs `int`,
# `__SIZE_TYPE__`, the whole `__LDBL_*` family — and a conditional that
# COMPARES one of them took the host's arm under a gate reporting
# `reconciled=48` (measured by a blind critic, 2026-09-21:
# `#if __SIZEOF_LONG_DOUBLE__ == 16 / #error` is red on the real target and
# green under the round-4 gate).
#
# Each of those gets `-U name -D name=<the target's value>` like any other
# difference. But a type macro can contradict glibc's own typedefs under
# -m32, so which ones survive is MEASURED, not assumed: the gate compiles a
# probe built from the system headers the population actually includes. The
# names that do not survive are printed as value_parity_unreconciled, derived
# every run, and a conditional TESTING one of them is FAIL BY NAME.

# Builds $HEADER_PROBE: every `#include <...>` any examined TU or src/*.h
# names, minus the ones this box does not have. Derived, cached per process.
# $1 = TU list file.
header_probe_init() {
    local list="$1" h
    [ -n "$HEADER_PROBE" ] && return 0
    { cat "$list"; ls "$REPO"/src/*.h "$REPO"/web/*.h 2>/dev/null; } | tr '\n' '\0' > "$RUN/probe-scan.list"
    local -a scan=()
    local f
    while IFS= read -r -d '' f; do scan+=("$f"); done < "$RUN/probe-scan.list"
    [ "${#scan[@]}" -gt 0 ] || return 1
    grep -hoE '^[ \t]*#[ \t]*include[ \t]*<[^>]+>' "${scan[@]}" 2>/dev/null \
        | sed 's/.*<//; s/>.*//' | sort -u > "$RUN/sysincludes"
    if ! [ -s "$RUN/sysincludes" ]; then
        echo "FAIL: no system header was found in the population, so the value-parity probe would be vacuous" >&2
        return 1
    fi
    : > "$RUN/sysincludes.avail"
    while IFS= read -r h; do
        printf '#include <%s>\n' "$h" > "$RUN/one_header.c"
        # Audited compile line: the -Werror trio is required on every compile
        # in this file by tools/werror_switch_check.sh.
        if clang -m32 -fsyntax-only -c \
                -Werror=switch -Werror=comment -Werror=misleading-indentation \
                -isystem "$STUB" -isystem /usr/include/x86_64-linux-gnu \
                "$RUN/one_header.c" >/dev/null 2>&1; then
            printf '%s\n' "$h" >> "$RUN/sysincludes.avail"
        fi
    done < "$RUN/sysincludes"
    if ! [ -s "$RUN/sysincludes.avail" ]; then
        echo "FAIL: none of the population's system headers compiles on this box, so the value-parity probe would be vacuous" >&2
        return 1
    fi
    {
        while IFS= read -r h; do printf '#include <%s>\n' "$h"; done < "$RUN/sysincludes.avail"
        printf 'int eigs_ilp32_header_probe(void);\n'
    } > "$RUN/header_probe.c"
    HEADER_PROBE="$RUN/header_probe.c"
    return 0
}

# Compiles $HEADER_PROBE under the flags in "$@". Status is the verdict.
header_probe_ok() {
    clang -m32 -fsyntax-only -c \
        -Werror=switch -Werror=comment -Werror=misleading-indentation \
        -isystem "$STUB" -isystem /usr/include/x86_64-linux-gnu \
        "$@" "$HEADER_PROBE" >"$RUN/header_probe.err" 2>&1
}

# $1 = tab-separated `name<TAB>target value` file, $2 = the name-difference
# flags array name, $3 = output file for the accepted flags (one per line),
# $4 = output file for the unreconcilable names.
# Tries the whole set first (one compile in the healthy case); only if glibc
# refuses it does it measure macro by macro which names are responsible.
value_parity_measure() {
    local valdiff="$1" basename_arr="$2" outflags="$3" outbad="$4"
    local m v pass
    local -a base=()
    eval "base=(\${$basename_arr[@]+\"\${$basename_arr[@]}\"})"
    local -a cand=()
    while IFS=$'\t' read -r m v; do
        [ -z "$m" ] && continue
        cand+=("-U$m" "-D$m=$v")
    done < "$valdiff"
    : > "$outbad"
    if [ "${#cand[@]}" -eq 0 ] || header_probe_ok "${base[@]}" "${cand[@]}"; then
        printf '%s\n' "${cand[@]+"${cand[@]}"}" > "$outflags"
        return 0
    fi
    # Measured, name by name: which single reconciliation glibc refuses.
    while IFS=$'\t' read -r m v; do
        [ -z "$m" ] && continue
        header_probe_ok "${base[@]}" "-U$m" "-D$m=$v" || printf '%s\n' "$m" >> "$outbad"
    done < "$valdiff"
    for pass in 1 2 3; do
        cand=()
        while IFS=$'\t' read -r m v; do
            [ -z "$m" ] && continue
            grep -qxF -- "$m" "$outbad" && continue
            cand+=("-U$m" "-D$m=$v")
        done < "$valdiff"
        if [ "${#cand[@]}" -eq 0 ] || header_probe_ok "${base[@]}" "${cand[@]}"; then
            printf '%s\n' "${cand[@]+"${cand[@]}"}" > "$outflags"
            return 0
        fi
        # A combination glibc refuses that no single name explains: drop the
        # names the last failure blamed, by name, and try again.
        grep -oE '__[A-Za-z0-9_]+__' "$RUN/header_probe.err" | sort -u >> "$outbad"
        sort -u "$outbad" -o "$outbad"
    done
    echo "FAIL: the value reconciliation could not be made to compile the population's own system headers, and no set of names explains it:" >&2
    sed 's/^/      /' "$RUN/header_probe.err" >&2
    return 1
}

# $1 = tested-names file, $2 = reconciliation flags array NAME, $3 = target
# names file, $4 = how many predefine differences those flags cover,
# $5 = world-macro list.
# Re-derives the HOST world UNDER the flags and asserts defined-ness parity for
# every tested macro. Sets MACRO_PARITY_REPORT. FAILS BY NAME on a mismatch.
macro_parity_verify() {
    local tested="$1" flagsname="$2" tnames="$3" ndiff="$4" world="$5"
    local eff="$RUN/host-eff.dM" enames="$RUN/host-eff.names"
    local m n_tested n_ok=0 bad='' in_t in_h n_world untested_bad=''
    local -a flags=()
    eval "flags=(\${$flagsname[@]+\"\${$flagsname[@]}\"})"
    n_tested=$(grep -c . "$tested")
    if [ "$n_tested" -eq 0 ]; then
        echo "FAIL: macro parity tested 0 macros — an empty population is not parity, it is a gate that measured nothing" >&2
        return 1
    fi
    derive_predefines "$eff" host ${flags[@]+"${flags[@]}"} || return 1
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
    # `reconciled` counts DEFINED-NESS; `values` counts the macros defined in
    # both worlds whose VALUE was compared and made equal. They are printed
    # separately on purpose: round 4 said "reconciled" of 48 macros while not
    # one value had been compared.
    MACRO_PARITY_REPORT="macro_parity: tested=$n_tested reconciled=$n_ok values=$VALUE_RECONCILED_N/$VALUE_DIFF_N value_parity_unreconciled=${VALUE_UNRECONCILED:-none} ($ndiff predefine differences reconciled; $n_world tested by the population:$(tr '\n' ' ' <<<"$world" | sed 's/ *$//;s/^/ /'))"
    if [ -n "$bad" ]; then
        echo "FAIL: macro parity could not reconcile these tested macro(s) between the wasm32-emscripten target and this gate's -m32 stand-in:$bad" >&2
        echo "      A tested macro whose defined-ness differs means the gate compiles a DIFFERENT arm from the lane it stands in for." >&2
        return 1
    fi
    # An unreconcilable VALUE is tolerable only while no conditional in the
    # population reads it. The moment one does, the gate is compiling a
    # different arm again, and that is the #1185 class.
    for m in $VALUE_UNRECONCILED; do
        grep -qxF -- "$m" "$tested" && untested_bad="$untested_bad $m"
    done
    if [ -n "$untested_bad" ]; then
        echo "FAIL: these macro(s) hold a DIFFERENT value on the wasm32-emscripten target, could not be reconciled under -m32 (glibc's own headers refuse the value), and are READ by a conditional in the examined population:$untested_bad" >&2
        echo "      The gate would compile the host's arm while emcc compiles the target's. Narrow the population or reconcile the value by hand." >&2
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
    local m v ndiff=0 flag
    local -a nameflags=()

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
        nameflags+=("-U$m")
        ndiff=$((ndiff + 1))
    done < "$only_h"
    while IFS= read -r m; do
        [ -z "$m" ] && continue
        if grep -q "^#define $m(" "$tgt"; then
            echo "FAIL: the target predefines $m as a function-like macro; this gate cannot reconcile it with a single -D" >&2
            return 1
        fi
        v=$(awk -v M="$m" '$2 == M { sub(/^#define[ \t]+[^ \t]+[ \t]*/, ""); print; exit }' "$tgt")
        nameflags+=("-D$m=$v")
        ndiff=$((ndiff + 1))
    done < "$only_t"

    # VALUE differences: defined in BOTH worlds, with different expansions.
    macro_value_map "$tgt" > "$RUN/target.map"
    macro_value_map "$hst" > "$RUN/host.map"
    join -t "$(printf '\t')" -j 1 "$RUN/target.map" "$RUN/host.map" \
        | awk -F'\t' '$2 != $3 { print $1 "\t" $2 }' > "$RUN/valdiff.map"
    VALUE_DIFF_N=$(grep -c . "$RUN/valdiff.map")
    header_probe_init "$list" || return 1
    if ! header_probe_ok "${nameflags[@]}"; then
        # NOT a fault in the tree: this toolchain's C library headers refuse to
        # be preprocessed once the host's own world is replaced by the
        # target's. macos-latest is the measured case — the reconciliation
        # removes `__i386__`/`__APPLE__` (that is its whole job) and the SDK
        # answers `sys/cdefs.h:1068: #error Unsupported architecture`. A
        # toolchain that cannot hold the target's macro world cannot stand in
        # for the lane, so the caller SKIPs by name with the toolchain's own
        # words. Stage 1 of the availability probe has already proved that the
        # SAME headers compile at -m32 WITHOUT the reconciliation, so this arm
        # is specific: it fires on a host whose libc is tied to its own
        # architecture macros, not on any compile failure.
        MACRO_PARITY_SKIP_REASON=$(cat "$RUN/header_probe.err")
        return 1
    fi
    value_parity_measure "$RUN/valdiff.map" nameflags "$RUN/valueflags" "$RUN/valuebad" || return 1
    VALUE_UNRECONCILED=$(tr '\n' ' ' < "$RUN/valuebad" | sed 's/ *$//')
    MACRO_PARITY_NAME_FLAGS=("${nameflags[@]}")
    MACRO_PARITY_FLAGS=("${nameflags[@]}")
    while IFS= read -r flag; do
        [ -z "$flag" ] && continue
        MACRO_PARITY_FLAGS+=("$flag")
    done < "$RUN/valueflags"
    VALUE_RECONCILED_N=$(( $(grep -c . "$RUN/valueflags") / 2 ))

    sort -u "$only_h" "$only_t" > "$RUN/diff.names"
    comm -12 "$tested" "$RUN/diff.names" > "$world"
    macro_parity_verify "$tested" MACRO_PARITY_FLAGS "$tnames" "$ndiff" "$(cat "$world")" || return 1
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
    local out st inc lang
    local -a xlang=()
    inc="-Isrc"
    [ -n "$extra_i" ] && inc="-I$extra_i -Isrc"
    lang=$(tu_language "$tu")
    [ -n "$lang" ] && xlang=(-x "$lang")
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
        ${MACRO_PARITY_FLAGS[@]+"${MACRO_PARITY_FLAGS[@]}"} \
        -DEIGENSCRIPT_VERSION="\"$EIGS_VERSION\"" \
        ${xlang[@]+"${xlang[@]}"} "$tu" 2>&1)
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
# compiler's name is true on the macOS runners, where the 32-bit C library is
# gone (Apple dropped 32-bit) and /usr/include/x86_64-linux-gnu does not exist —
# so a name probe would turn this gate into a NEW red lane on runners it has
# nothing to say about, which is the opposite of why it exists. There is no
# separate name test either: an absent toolchain fails this same probe with the
# shell's own "command not found", so ONE path covers both, and no line in this
# file names a compiler outside an actual compile invocation (a name on any
# other line is an unaccounted-shape failure in [99i]'s recognizer coverage).
#
# THE PROBE MUST ASK FOR THE CAPABILITY THE GATE USES. Round 3's probe compiled
# a one-line TU with NO includes, which clang accepts at `-m32` on an arm64 mac
# — it never reaches a header. Measured on macos-latest at 8097088: the probe
# passed, the gate proceeded, and all 23 real TUs failed with
# `MacOSX.sdk/usr/include/sys/cdefs.h:1068: error: Unsupported architecture`,
# turning this gate into exactly the new red lane the paragraph above says it
# must not be. So the probe now includes the C library, which is what every TU
# in the population does on its first line. A capability probe that stops short
# of the capability is a name probe with extra steps.
#
# The skip is announced with the toolchain's own words (mechanical-gates §155:
# a skip is a claim, and a silent one reads as coverage). If the Linux lane
# ever starts skipping, the reason is printed right there.
#
# $1 = the stub include dir to probe with. Prints the toolchain's own words on
# failure and nothing on success; status is the verdict. Taking the stub dir as
# an argument is what makes the SKIP arm testable: self-test plant 5s probes
# with a stub whose <stdlib.h> refuses, and requires "unavailable".
ilp32_capability_probe() {
    local stubdir="$1" out
    printf '%s\n' '#include <stdlib.h>' '#include <stdio.h>' \
                  'int eigs_ilp32_probe(void) { return 0; }' > "$stubdir/probe_avail.c"
    # The -Werror= trio is not load-bearing for a three-line probe; it is here
    # because tools/werror_switch_check.sh audits every compile line in this
    # script by SOURCE TEXT, and an audited line without them is a violation.
    if out=$(clang -m32 -fsyntax-only -c \
            -Werror=switch -Werror=comment -Werror=misleading-indentation \
            -isystem "$stubdir" -isystem /usr/include/x86_64-linux-gnu \
            "$stubdir/probe_avail.c" 2>&1); then
        return 0
    fi
    printf '%s\n' "$out"
    return 1
}

if ! avail_err=$(ilp32_capability_probe "$STUB"); then
    echo "SKIP: this toolchain cannot compile a 32-bit C translation unit against its own C library — the playground's 32-bit shape was NOT checked"
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
echo "classifier: $CLASSIFIER_N_FS input(s) by suffix+filesystem, $CLASSIFIER_N_DRV by the driver derivation, $N_LIVE_TUS in the union examined"

if ! macro_parity_init "$LIVE_TUS"; then
    if [ -n "$MACRO_PARITY_SKIP_REASON" ]; then
        echo "SKIP: this toolchain's C library headers cannot be preprocessed at 32 bits in the wasm32 target's macro world — the playground's 32-bit shape was NOT checked"
        printf '%s\n' "$MACRO_PARITY_SKIP_REASON" | sed 's/^/      /'
        exit 0
    fi
    exit 1
fi
echo "$MACRO_PARITY_REPORT"

if [ "$SELFTEST" -eq 0 ]; then
    # Examine FIRST: a disagreement between the two derivations is reported on
    # top of the union's own verdict, never instead of it, so the planted TU
    # that caused the disagreement is still compiled and still named.
    examine_tus "$LIVE_TUS" "" "$STUB" "$TU_FLOOR"
    examine_rc=$?
    if [ -s "$CLASSIFIER_DIFF_FILE" ]; then
        echo "FAIL: the two independent derivations of the population DISAGREE. The gate examined their UNION, but a disagreement means one of the two rules is wrong about what emcc compiles — and the next one may be wrong in the direction that hides a TU:" >&2
        sed 's/^/  /' "$CLASSIFIER_DIFF_FILE" >&2
        exit 1
    fi
    exit $examine_rc
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
# none), $6 content to write at $4 before the recipe runs (empty = none),
# $7 a literal substring the CLASSIFIER DISAGREEMENT must contain (empty = the
# two derivations must AGREE exactly). $7 is what keeps the second derivation
# honest: a plant that says "agree" goes red the moment either half stops
# deriving, which is how gutting the response-file expansion is caught.
# The scratch recipe is read from "$WORK/$key.sh".
argv_plant() {
    local key="$1" label="$2" want_delta="$3" want_present="$4" want_absent="$5" tu_content="${6:-}" want_diff="${7:-}"
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
    if [ -z "$want_diff" ]; then
        if [ -s "$sbx/.eigs-ilp32-classifier-diff" ]; then
            echo "selftest FAIL: $label — the suffix+filesystem rule and the driver derivation produced DIFFERENT populations, and this plant requires them to agree:"
            sed 's/^/      /' "$sbx/.eigs-ilp32-classifier-diff"
            fails=1
            return
        fi
    elif ! grep -qF -- "$want_diff" "$sbx/.eigs-ilp32-classifier-diff"; then
        echo "selftest FAIL: $label — the classifier disagreement does not name '$want_diff'; it says:"
        sed 's/^/      /' "$sbx/.eigs-ilp32-classifier-diff"
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

# ---- the OPTION-GRAMMAR plants (2f, 2p, 2r, 2n, 2i, 2u, 2e) --------------
# Round 4 classified argv with a hand-typed model of emcc's option grammar.
# Every plant here is a shape that model read WRONG, in the direction that
# HIDES a translation unit emcc compiles. They all run through the REAL
# sandbox_record_inputs, so they test the derivation, not a restatement of it.
# Each also asserts whether the two independent derivations AGREE — that
# assertion is what goes red if either half is gutted.

# 2f / 2p: emcc FLAGS that take no operand (`--emrun` is check_flag in
# cmdline.py; `--proxy-to-worker` is in LEGACY_FLAGS). Round 4 listed both as
# operand-taking, so the TU sitting after one of them was dropped from the
# population while emcc compiled it — and the gate printed `OK: examined 23`.
awk '{ print } /^[ \t]*"\$\{SOURCES\[@\]\}"[ \t]*\\[ \t]*$/ { print "    --emrun web/eigs_ilp32_plant_2f.c \\" }' \
    "$BUILD_SH" > "$WORK/2f.sh"
argv_plant 2f "plant 2f a TU after --emrun (no operand in emcc) is examined (24 of 24)" \
    1 "web/eigs_ilp32_plant_2f.c" "" '#error EIGS_ILP32_PLANT_2F' ""

awk '{ print } /^[ \t]*"\$\{SOURCES\[@\]\}"[ \t]*\\[ \t]*$/ { print "    --proxy-to-worker web/eigs_ilp32_plant_2p.c \\" }' \
    "$BUILD_SH" > "$WORK/2p.sh"
argv_plant 2p "plant 2p a TU after --proxy-to-worker (a legacy flag, no operand) is examined (24 of 24)" \
    1 "web/eigs_ilp32_plant_2p.c" "" '#error EIGS_ILP32_PLANT_2P' ""

# 2r: a RESPONSE FILE, written by the recipe and expanded by emcc before any
# option is parsed. Round 4 never expanded one, so the whole compile line
# inside it was invisible. The recipe generates it, which is how a real build
# system produces one.
awk '/^emcc /            { print "printf '"'"'web/eigs_ilp32_plant_2r.c\\n'"'"' > web/eigs_ilp32_plant_2r.rsp" }
     { print }
     /^[ \t]*"\$\{SOURCES\[@\]\}"[ \t]*\\[ \t]*$/ { print "    @web/eigs_ilp32_plant_2r.rsp \\" }' \
    "$BUILD_SH" > "$WORK/2r.sh"
argv_plant 2r "plant 2r a TU named only inside an @response-file is examined (24 of 24)" \
    1 "web/eigs_ilp32_plant_2r.c" "" '#error EIGS_ILP32_PLANT_2R' ""

# 2n: response files nested THREE deep. Two levels are expanded; a third is
# FAIL BY NAME, never a silently truncated population.
awk '/^emcc /            { print "printf '"'"'@web/eigs_ilp32_plant_2n_b.rsp\\n'"'"' > web/eigs_ilp32_plant_2n_a.rsp"
                           print "printf '"'"'@web/eigs_ilp32_plant_2n_c.rsp\\n'"'"' > web/eigs_ilp32_plant_2n_b.rsp"
                           print "printf '"'"'src/fsutil.c\\n'"'"' > web/eigs_ilp32_plant_2n_c.rsp" }
     { print }
     /^[ \t]*"\$\{SOURCES\[@\]\}"[ \t]*\\[ \t]*$/ { print "    @web/eigs_ilp32_plant_2n_a.rsp \\" }' \
    "$BUILD_SH" > "$WORK/2n.sh"
if ! sandbox_prepare "$WORK/sbx-2n" "$WORK/2n.sh" 2>"$WORK/2n.prep.err"; then
    echo "selftest FAIL: plant 2n could not be staged:"
    sed 's/^/      /' "$WORK/2n.prep.err"
    fails=1
elif sandbox_record_inputs "$WORK/sbx-2n" "$WORK/2n.tus" 2>"$WORK/2n.err"; then
    echo "selftest FAIL: plant 2n (response files nested three deep) was accepted — the gate expanded part of the population and called it all of it"
    fails=1
elif grep -q 'nest more than two deep' "$WORK/2n.err"; then
    echo "selftest ok: plant 2n response files nested three deep is FAIL by name"
else
    echo "selftest FAIL: plant 2n went red for the wrong reason:"
    sed 's/^/      /' "$WORK/2n.err"
    fails=1
fi

# 2i: a translation unit on STANDARD INPUT (`-x c -`). No argument names it,
# so no rule over argv text can ever see it; the stand-in captures it instead,
# and only when `-` is really in argv.
awk '/^emcc /            { print "printf '"'"'#error EIGS_ILP32_PLANT_2I\\n'"'"' > web/eigs_ilp32_plant_2i.c" }
     { print }
     /^[ \t]*"\$\{SOURCES\[@\]\}"[ \t]*\\[ \t]*$/ { print "    -x c - -x none \\" }
     /^[ \t]*-o web\/dist\/eigs\.js[ \t]*$/ { }' \
    "$BUILD_SH" | sed 's|^\( *\)-o web/dist/eigs\.js$|\1-o web/dist/eigs.js < web/eigs_ilp32_plant_2i.c|' \
    > "$WORK/2i.sh"
argv_plant 2i "plant 2i a TU on standard input (-x c -) is captured and examined (24 of 24)" \
    1 ".eigs-ilp32-stdin.c" "" "" ""

# 2u: a unit whose SUFFIX is not a TU suffix, compiled as C by `-x c`. The
# suffix rule cannot see it and says so: the two derivations disagree, the
# gate examines their UNION so the fault inside is still found, and the
# disagreement is named.
awk '{ print } /^[ \t]*"\$\{SOURCES\[@\]\}"[ \t]*\\[ \t]*$/ { print "    -x c web/eigs_ilp32_plant_2u.inc -x none \\" }' \
    "$BUILD_SH" > "$WORK/2u.sh"
argv_plant 2u "plant 2u a unit whose suffix is not a TU suffix is examined, and the suffix rule says so (24 of 24)" \
    1 "web/eigs_ilp32_plant_2u.inc" "" '#error EIGS_ILP32_PLANT_2U' "only the driver derivation"

# 2e: the OVER-INCLUSION control, and the residual this gate states rather
# than hides. `--embed-file web/x.c` hands emcc a DATA file that happens to be
# named `.c`; both derivations count it and the gate goes red by name on it.
# That direction is fail-loud, not silent, and this plant pins it as such.
awk '{ print } /^[ \t]*"\$\{SOURCES\[@\]\}"[ \t]*\\[ \t]*$/ { print "    --embed-file web/eigs_ilp32_plant_2e.c \\" }' \
    "$BUILD_SH" > "$WORK/2e.sh"
argv_plant 2e "control 2e a DATA file named .c behind --embed-file is counted and RED BY NAME (stated over-inclusion)" \
    1 "web/eigs_ilp32_plant_2e.c" "" 'EIGS_ILP32_PLANT_2E is data, not C source' ""

# 2w: the SANDBOX claim. Round 4 symlinked every top-level entry, so a recipe
# line writing `src/x.h` wrote into the real src/. The header said "nothing is
# written back into the tree"; the mechanism protected web/ alone.
awk '/^emcc / { print "printf '"'"'/* planted */\\n'"'"' > src/eigs_ilp32_plant_2w.h" } { print }' \
    "$BUILD_SH" > "$WORK/2w.sh"
if ! sandbox_prepare "$WORK/sbx-2w" "$WORK/2w.sh" 2>"$WORK/2w.prep.err"; then
    echo "selftest FAIL: plant 2w could not be staged:"
    sed 's/^/      /' "$WORK/2w.prep.err"
    fails=1
elif ! sandbox_record_inputs "$WORK/sbx-2w" "$WORK/2w.tus" 2>"$WORK/2w.err"; then
    echo "selftest FAIL: plant 2w — the recipe that writes into src/ did not complete:"
    sed 's/^/      /' "$WORK/2w.err"
    fails=1
elif ! [ -f "$WORK/sbx-2w/src/eigs_ilp32_plant_2w.h" ]; then
    echo "selftest FAIL: plant 2w was a no-op — the recipe line never wrote the file, so the sandbox proved nothing"
    fails=1
elif [ -e "$REPO/src/eigs_ilp32_plant_2w.h" ]; then
    echo "selftest FAIL: plant 2w — a recipe line writing src/eigs_ilp32_plant_2w.h LANDED IN THE WORKING TREE; the sandbox protects web/ only"
    rm -f "$REPO/src/eigs_ilp32_plant_2w.h"
    fails=1
else
    echo "selftest ok: plant 2w a recipe writing src/ lands in the sandbox and NOT in the working tree"
fi

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

# ---- VALUE-parity plants (4v, 4vc, 4w, 4y) -------------------------------
# Round 4 reconciled defined-ness only. 4v is the measured gap: a conditional
# that COMPARES a predefine both worlds define with different values.
printf '%s\n' '#if __SIZEOF_LONG_DOUBLE__ == 16' '#error EIGS_ILP32_PLANT_4V' '#endif' \
              'int eigs_ilp32_plant_4v(void);' > "$WORK/plant4v.c"
expect_tu_red plant4v "plant 4v a conditional comparing a predefine whose VALUE differs (long double is 16 on wasm32, 12 on the -m32 host)" \
    "$WORK/plant4v.c" "EIGS_ILP32_PLANT_4V"

# 4vc is its control: the HOST's value must NOT be the one the gate compiles
# with, or "red" would only mean "this probe is always red".
printf '%s\n' '#if __SIZEOF_LONG_DOUBLE__ == 12' '#error EIGS_ILP32_PLANT_4VC' '#endif' \
              'int eigs_ilp32_plant_4vc(void);' > "$WORK/plant4vc.c"
if compile_tu "$WORK/plant4vc.c" "" "$STUB" 2>"$WORK/plant4vc.err"; then
    echo "selftest ok: control 4vc the host's long-double value is NOT the one the gate compiles with"
else
    echo "selftest FAIL: control 4vc — the gate still carries the -m32 host's __SIZEOF_LONG_DOUBLE__:"
    sed 's/^/      /' "$WORK/plant4vc.err"
    fails=1
fi

# 4w: the MEASUREMENT half. A value reconciliation glibc's own headers refuse
# must be found BY NAME and dropped, not silently applied (which would turn
# the whole population red for a reason that has nothing to do with the code).
printf '%s\t%s\n' __SIZE_TYPE__ 'struct eigs_ilp32_plant_4w_t' > "$WORK/plant4w.map"
if ! value_parity_measure "$WORK/plant4w.map" MACRO_PARITY_NAME_FLAGS \
        "$WORK/plant4w.flags" "$WORK/plant4w.bad" 2>"$WORK/plant4w.err"; then
    echo "selftest FAIL: plant 4w (a value glibc refuses) made the measurement give up instead of naming it:"
    sed 's/^/      /' "$WORK/plant4w.err"
    fails=1
elif grep -qx '__SIZE_TYPE__' "$WORK/plant4w.bad"; then
    echo "selftest ok: plant 4w a value reconciliation glibc's headers refuse is measured and named ($(tr '\n' ' ' < "$WORK/plant4w.bad" | sed 's/ *$//'))"
else
    echo "selftest FAIL: plant 4w — the refused reconciliation was not named; unreconciled set was '$(tr '\n' ' ' < "$WORK/plant4w.bad")'"
    fails=1
fi

# 4y: an unreconcilable value is tolerable only while nothing READS it. Feed
# the verifier a name that IS tested by the population and require a FAIL by
# name — otherwise value_parity_unreconciled would be a report with no teeth.
VALUE_UNRECONCILED_SAVED="$VALUE_UNRECONCILED"
VALUE_UNRECONCILED='__linux__'
if ! grep -qx '__linux__' "$RUN/tested.names"; then
    echo "selftest FAIL: plant 4y cannot run — __linux__ is no longer in the tested population, so the plant would be vacuous"
    fails=1
elif macro_parity_verify "$RUN/tested.names" MACRO_PARITY_FLAGS "$RUN/target.names" 0 "" \
        >/dev/null 2>"$WORK/plant4y.err"; then
    echo "selftest FAIL: plant 4y (an unreconcilable value that a conditional reads) passed — value_parity_unreconciled is a report with no assertion behind it"
    fails=1
elif grep -q 'are READ by a conditional' "$WORK/plant4y.err"; then
    echo "selftest ok: plant 4y an unreconcilable VALUE that the population reads is FAIL by name"
else
    echo "selftest FAIL: plant 4y went red for the wrong reason:"
    sed 's/^/      /' "$WORK/plant4y.err"
    fails=1
fi
VALUE_UNRECONCILED="$VALUE_UNRECONCILED_SAVED"

# 2t: the parity population must not shrink SILENTLY. Round 4 scanned the TU
# list with `awk ... $(cat "$files")` unquoted and never checked awk's status:
# one path with a space made awk fail on that file and `tested=48` became
# `tested=19` with exit 0 (measured by a blind critic, 2026-09-21).
N_TESTED_LIVE=$(grep -c . "$RUN/tested.names")
cp "$REPO/src/fsutil.c" "$WORK/eigs ilp32 plant 2t.c"
{ cat "$LIVE_TUS"; printf '%s\n' "$WORK/eigs ilp32 plant 2t.c"; } > "$WORK/2t.tus"
if ! tested_macros "$WORK/2t.tus" "$WORK/2t.names" 2>"$WORK/2t.err"; then
    echo "selftest FAIL: plant 2t — a TU path containing a space broke the conditional scan outright:"
    sed 's/^/      /' "$WORK/2t.err"
    fails=1
elif [ "$(grep -c . "$WORK/2t.names")" -lt "$N_TESTED_LIVE" ]; then
    echo "selftest FAIL: plant 2t — a TU path with a space shrank the tested-macro population from $N_TESTED_LIVE to $(grep -c . "$WORK/2t.names") and said nothing"
    fails=1
else
    echo "selftest ok: plant 2t a TU path with a space does not shrink the tested-macro population ($(grep -c . "$WORK/2t.names") >= $N_TESTED_LIVE)"
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

# Plant 5s: the SKIP arm. Round 3's availability probe compiled a TU with no
# includes, which an arm64 mac accepts at -m32 because it never reaches a
# header — so the probe passed on macos-latest and all 23 real TUs then failed
# on `sys/cdefs.h: #error Unsupported architecture`. The probe now includes the
# C library; this plant proves that arm can still say "unavailable", by giving
# it a stub whose <stdlib.h> refuses. Without it the SKIP branch is a claim no
# case ever exercises.
mkdir -p "$WORK/skipstub/gnu"
: > "$WORK/skipstub/gnu/stubs-32.h"
printf '%s\n' '#error EIGS_ILP32_PLANT_5S_NO_32BIT_LIBC' > "$WORK/skipstub/stdlib.h"
if ilp32_capability_probe "$WORK/skipstub" > "$WORK/plant5s.out" 2>&1; then
    echo "selftest FAIL: plant 5s (a toolchain with no 32-bit C library) was reported AVAILABLE — the gate would run against headers it cannot use and go red on every TU"
    fails=1
elif grep -q 'EIGS_ILP32_PLANT_5S_NO_32BIT_LIBC' "$WORK/plant5s.out"; then
    echo "selftest ok: plant 5s a toolchain with no 32-bit C library is reported unavailable, with the toolchain's own words"
else
    echo "selftest FAIL: plant 5s went red for the wrong reason:"
    sed 's/^/      /' "$WORK/plant5s.out"
    fails=1
fi

# Control 5sc: the LIVE stub must still be reported available, or "unavailable"
# would only mean "this probe always says no".
if ilp32_capability_probe "$STUB" > "$WORK/plant5sc.out" 2>&1; then
    echo "selftest ok: control 5sc this toolchain's own 32-bit C library probe is available"
else
    echo "selftest FAIL: control 5sc — the live availability probe now says unavailable, so the whole run below it was vacuous:"
    sed 's/^/      /' "$WORK/plant5sc.out"
    fails=1
fi

# Plant 5r / control 5rc: the SECOND skip arm — a toolchain whose C library
# cannot be preprocessed in the target's macro world. macos-latest is the
# measured case (the reconciliation removes `__i386__`/`__APPLE__`, which is
# its job, and the SDK answers `#error Unsupported architecture`). The plant
# points the DERIVED header probe at one that refuses and requires the real
# macro_parity_init to report a SKIP reason naming it; the control requires
# this toolchain not to take that arm, or everything below it was vacuous.
HEADER_PROBE_SAVED="$HEADER_PROBE"
printf '%s\n' '#error EIGS_ILP32_PLANT_5R_NO_TARGET_MACRO_WORLD' > "$WORK/poison_probe.c"
HEADER_PROBE="$WORK/poison_probe.c"
MACRO_PARITY_SKIP_REASON=''
if macro_parity_init "$LIVE_TUS" >/dev/null 2>"$WORK/plant5r.err"; then
    echo "selftest FAIL: plant 5r (a C library that refuses the target's macro world) was accepted — the gate would report parity it never verified"
    fails=1
elif grep -q 'EIGS_ILP32_PLANT_5R_NO_TARGET_MACRO_WORLD' <<<"$MACRO_PARITY_SKIP_REASON"; then
    echo "selftest ok: plant 5r a C library that refuses the target's macro world is reported as a SKIP reason, by name"
else
    echo "selftest FAIL: plant 5r went red for the wrong reason (skip reason '$MACRO_PARITY_SKIP_REASON'):"
    sed 's/^/      /' "$WORK/plant5r.err"
    fails=1
fi
HEADER_PROBE="$HEADER_PROBE_SAVED"
MACRO_PARITY_SKIP_REASON=''
if macro_parity_init "$LIVE_TUS" >/dev/null 2>"$WORK/plant5rc.err" \
   && [ -z "$MACRO_PARITY_SKIP_REASON" ]; then
    echo "selftest ok: control 5rc this toolchain holds the target's macro world, so the skip arm is not taken here"
else
    echo "selftest FAIL: control 5rc — the live run now takes the skip arm, so every plant above it measured nothing (skip reason '$MACRO_PARITY_SKIP_REASON'):"
    sed 's/^/      /' "$WORK/plant5rc.err"
    fails=1
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
