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
# RESIDUALS THE LOOP MEASURED AND THIS GATE DOES NOT CLOSE. Each was reached by
# a blind critic on a real run (2026-09-21) and is written here rather than
# implied, because a limitation nobody wrote down is a claim of coverage:
#
#   * BOTH `emcc` AND `em++` ARE SHIMMED (#1232 item 9); no THIRD driver name
#     is. `emar`/`emranlib` are archiver/linker steps, not compilers, and are
#     out of scope by construction. A recipe that reaches some other C/C++
#     driver spelling is still recorded nowhere; extend STANDIN_BIN with that
#     name before adding it to web/build.sh.
#   * THE RECORDED INPUT IS READ AT SANDBOX-CLEANUP TIME, NOT AT CALL TIME
#     (#1232 item 10, stated, not closed). The stand-in records argv/cwd/
#     created/stdin per call but does not SNAPSHOT each input TU's bytes at
#     the moment of that call; `examine_tus` reads whatever the file holds
#     after the WHOLE recipe finishes. A recipe that writes `#error` into a
#     unit, compiles it, then overwrites the same path with valid C before a
#     LATER call reads it would be examined on the later bytes and pass,
#     while the real first call actually saw the `#error`. Closing this needs
#     each call to copy (or hash-and-copy) its own input TUs into its own
#     record directory and have examine_tus read that snapshot instead of the
#     live sandbox path — not implemented.
#   * AN INVALID OPTION THE DRIVER REJECTS IS SILENTLY DROPPED (#1232 item 13,
#     stated, not closed — Astra rank 5). `driver_rejects_option` cannot tell
#     "an emcc-only setting clang doesn't know" from "a typo no compiler
#     accepts": `-fR6-invalid-option` is classified emcc-only and dropped from
#     the driver cross-check the same way `-sTOTAL_MEMORY=64MB` legitimately
#     is, so the gate passes a recipe the real frontend — emcc, which shares
#     clang's own diagnoser — would refuse. The recipe's real build (the pages
#     lane, once buildable) is the oracle for the recipe's own validity; this
#     gate is not.
#   * `value_parity_unreconciled=` is exercised only by self-test plants 4w and
#     4y. On this box and in CI the live line prints `value_parity_unreconciled=
#     none`, so the real population has never driven that branch; the plants are
#     its only evidence.
#   * TWO WRONG-REASON REDS. Both are loud and neither names the translation
#     unit: a DIRECTORY named `web/foo.c` on the compile line dies in the
#     conditional scan (`awk: read error (Is a directory)` ->
#     `FAIL: the preprocessor-conditional scan exited non-zero`), and an
#     UNREADABLE (mode 000) `.c` dies one step earlier, in staging (`cp: cannot
#     open` -> `FAIL: could not stage the playground recipe in a scratch
#     sandbox`). emcc would refuse both too, so the lane cannot go green on
#     them; the diagnostic just points at the apparatus instead of the file.
#   * `EIGS_ILP32_TU_FLOOR` IS AN ENV KNOB. A caller exporting 0 or 1 makes the
#     population floor vacuous on a STANDALONE invocation. Where the suite runs
#     this gate the section is covered — self-test plants 3 and 3b go red on a
#     lowered floor — but nothing constrains a lane that exports it and runs
#     the tool directly.
#
# Usage: tools/ilp32_syntax_check.sh [--selftest]
#   --selftest : plant 55 faults through the REAL derive/record/classify/
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
#                    (must FAIL by name), (2i) a TU on standard input, (12es)
#                    EMPTY stdin as a valid empty unit (`[ -s ]` read an empty
#                    capture as "nothing captured" — #1232 item 12),
#                    (2u) a `-x c` unit with a non-TU suffix (examined, and the
#                    suffix rule's disagreement named), (2e) the over-inclusion
#                    control: a DATA file named `.c` behind `--embed-file` is
#                    counted and red BY NAME;
#                  THE RECORDER  (2c) a TU compiled by an EARLIER invocation
#                    than the link line, (2ca) a pure compile-then-link recipe
#                    (its CALL count and its population both asserted), (2cz) a
#                    recipe with zero invocations (must FAIL by name), (2b) an
#                    EMPTY TU produced by one call's `-o` and compiled by the
#                    next (must be examined and COUNTED, not read as a silent
#                    shrink), (9e) a recipe line reaching `em++` rather than
#                    `emcc` (both are shimmed — #1232 item 9);
#                  DRIVER OPERANDS  (3s) emcc's spaced `-s TOTAL_MEMORY=64MB`
#                    (dropped from the driver call and REPORTED, never a red),
#                    (3sj) the glued form as its control, (3st) a `.c` token
#                    naming no existing file (must FAIL by name, never a drop),
#                    (3stx) the same on the axis a suffix cannot express — a
#                    `-x c <unit>` naming no existing file (must FAIL by name,
#                    never a drop);
#                  sandbox  (2w) a recipe line writing `src/` lands in the
#                    sandbox and NOT in the working tree, (2wp) the same write
#                    placed BEFORE the recipe's own `cd` — the side of that cd
#                    2w cannot reach;
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
#                  #1232 — the recorded call's FLAGS, not only its inputs
#                    (8o) an arm only taken under the recipe's OWN -O2, with
#                    (8oc) its transverse control (withholding the flags makes
#                    the SAME probe compile clean — the false PASS a blind
#                    critic reproduced through the real section, 46/46 green),
#                    (8d) a fault visible only under an EARLIER call's own -D
#                    reaching the compile (per-call, not a flat merge);
#                  population size  (2) an empty TU list, (3) a population
#                    below the floor, (3b) the entry point dropped from the
#                    inventory;
#                  availability — ONLY THE SDK'S OWN REFUSAL MAY SKIP
#                    (5s) a C library refusing the architecture in the SDK's
#                    own words must SKIP by name, with (5sc) the live
#                    toolchain as its control, and (5s2) the SECOND wording the
#                    same SDK emits (`architecture not supported`, measured on
#                    macos-latest in the same probe as the first) must SKIP too,
#                    with (5sg) glibc's own `You need a ISO C` refusal as the
#                    control that must still FAIL; (5b1) no compiler on PATH,
#                    (5b2) the gate's own stub missing and (5b3) a system
#                    include directory that does not exist must each FAIL BY
#                    NAME — round 5 skipped on all three; and at the macro-
#                    world stage, which is the one macos-latest reaches,
#                    (5rs) the SDK's own refusal of the RECONCILED world must
#                    be a SKIP reason by name while (5r) any other refusal is
#                    a FAIL by name. Round 5's control 5rc is not a case here
#                    any more: it runs in the LIVE path, before that verdict;
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

# Classifier state, set by sandbox_record_inputs: how many compiler
# invocations the recipe made, the size of each of the two independent
# derivations over the UNION of those calls, the tokens dropped from the
# driver cross-check, and the file naming the two derivations' disagreement
# (empty file = they agree). The CALLER owns the verdict on that file.
CLASSIFIER_N_CALLS=0
CLASSIFIER_N_FS=0
CLASSIFIER_N_DRV=0
CLASSIFIER_DROPPED=''
CLASSIFIER_DIFF_FILE=''
# path<TAB>language for every input the driver derivation reported, so a unit
# whose suffix is not a TU suffix (`-x c web/unit.inc`) is compiled AS the
# driver compiles it instead of being handed to clang suffix-first.
TU_LANG_MAP=''
# #1232: the recorded call's own FLAGS, not only its inputs. The live recipe
# compiles at `-O2`, which defines `__OPTIMIZE__`; the gate derived both macro
# worlds and compiled every TU with NEITHER the target's optimisation level
# nor any recorded -D, so `#if defined(__wasm__) && defined(__OPTIMIZE__)`
# compiled clean under the gate and is RED under real wasm clang at -O2
# (measured by a blind critic, 2026-09-21, src/fsutil.c). TU_CALL_DIR_MAP maps
# path<TAB>call-dir the SAME way TU_LANG_MAP maps path<TAB>language — first
# call to report a TU wins, which is also what makes a TU compiled once under
# one call's flags and again (unqualified) inside a later call's SOURCES
# examined under the call that actually shaped it. CALL_FLAGS_ALL is the
# UNION, deduplicated, of every recorded call's accepted flags; it is what
# shapes the macro-WORLD derivation, because there is one target/host
# predefine set per run, not one per call — the live recipe issues exactly one
# call, so union and per-call agree there, and a multi-call recipe with
# genuinely divergent optimisation levels is a residual this file states.
TU_CALL_DIR_MAP=''
CALL_FLAGS_ALL=()
# Cross-counts for the conditional scan (see tested_macros).
TESTED_CONDITIONAL_LINES=0
TESTED_SCAN_FILES=0
# The derived system-header probe used to measure which value reconciliations
# the host's own headers refuse. Built once per process.
HEADER_PROBE=''
# Set by macro_parity_init ONLY when this toolchain's C library refuses the
# TARGET's macro world with the SDK's own "Unsupported architecture" — the
# same capability absence the availability probe names, reached one stage
# later, and the stage macos-latest actually reaches. Any OTHER refusal is a
# FAIL by name, decided after the control runs (round 5 skipped on all of
# them; see macro_parity_init).
MACRO_PARITY_SKIP_REASON=''

# ---- scratch state --------------------------------------------------------
# STUB: the two headers this box lacks. RUN: sandboxes, recorded argv, derived
# macro sets. WORK: the selftest's own scratch. None of them is in the tree.
STUB=$(mktemp -d "${TMPDIR:-/tmp}/eigs-ilp32-stub-XXXXXX")
RUN=$(mktemp -d "${TMPDIR:-/tmp}/eigs-ilp32-run-XXXXXX")
TU_LANG_MAP="$RUN/tu.lang"
: > "$TU_LANG_MAP"
TU_CALL_DIR_MAP="$RUN/tu.call"
: > "$TU_CALL_DIR_MAP"
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
# EVERY INVOCATION IS RECORDED. Round 5's stand-in wrote its four records with
# `>`, so a recipe that invoked the compiler more than once kept only the LAST
# call: a planted `#error` unit compiled by a first `emcc -c web/x.c -o
# web/dist/x.o` and linked by the second call was outside the population
# entirely and the gate printed `OK: examined 23` while the real target was RED
# (measured by a blind critic, 2026-09-21). Compile-then-link is the canonical
# build shape. So each call now APPENDS a record of its own: the stand-in
# allocates the next `call-NNNN` directory under EIGS_ILP32_REC_DIR with
# `mkdir` (which is atomic, so two concurrent calls cannot collide) and writes
# its four facts there. The assumption that is now true, stated: EVERY
# INVOCATION OF THE STAND-IN IS RECORDED, and the population is the UNION over
# all of them. A recipe that never invokes the compiler is FAIL by name.
#
# The four FILESYSTEM facts, never a reading of emcc's option grammar:
#   argv     one argument per NUL;
#   cwd      the directory the recipe was in when it invoked the compiler, so
#            every relative argument resolves the way the compiler resolved it
#            (a recipe that `cd`s elsewhere no longer needs the gate to guess);
#   created  every file THIS call wrote. It writes the `-o` target so a recipe
#            that copies or lists its own output completes; that is the
#            stand-in's compiler role, not the classifier's. What the
#            classifier takes from it is a fact no suffix can give: a file the
#            COMPILER produced in THIS call is that call's output, never that
#            call's input. It is per-call on purpose: a `.c` written by call 1
#            and handed to call 2 is a translation unit emcc really compiles,
#            and is examined;
#   stdin    the translation unit on standard input, captured only when `-` is
#            actually in argv, so a recipe that redirects nothing never blocks.
STANDIN_BIN="$RUN/standin"
mkdir -p "$STANDIN_BIN"
cat > "$STANDIN_BIN/emcc" <<'EIGS_ILP32_STANDIN'
#!/usr/bin/env bash
rec="${EIGS_ILP32_REC_DIR:?}"
n=1
while :; do
    d=$(printf '%s/call-%04d' "$rec" "$n")
    mkdir "$d" 2>/dev/null && break
    n=$((n + 1))
    [ "$n" -gt 10000 ] && exit 1
done
printf '%s\0' "$@" > "$d/argv"
printf '%s\n' "$PWD" > "$d/cwd"
: > "$d/created"
prev=
for a in "$@"; do
    if [ "$prev" = "-o" ]; then
        mkdir -p "$(dirname "$a")" 2>/dev/null
        if : > "$a" 2>/dev/null; then
            p=$a
            case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
            printf '%s\n' "$p" >> "$d/created"
        fi
    fi
    prev=$a
done
for a in "$@"; do
    if [ "$a" = "-" ]; then
        cat > "$d/stdin.c"
        break
    fi
done
exit 0
EIGS_ILP32_STANDIN
chmod +x "$STANDIN_BIN/emcc"
# #1232 item 9 (Astra rank 2): emsdk installs TWO C/C++ compiler drivers,
# `emcc` (C) and `em++` (C++) — `emar`, `emranlib` etc. are not compilers and
# a recipe reaching one of them is an archiver/linker step this gate does not
# examine. Round 6 shimmed only `emcc`, so a recipe line reaching `em++`
# missed the stand-in on a box WITHOUT emsdk (loud rc 127, `em++: command not
# found` — measured) and would have missed the RECORDING entirely on a box
# WITH one (the real driver runs, compiles, and its TU is outside the
# population). Same script, same behaviour: a symlink, not a second copy that
# could drift.
ln -sf emcc "$STANDIN_BIN/em++"

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

# #1232: the recorded call's own FLAGS, not only its inputs. $1 = the
# expanded NUL-separated argv of ONE call. Prints, one per NUL, every token
# in the four classes an emcc/clang optimisation and define surface actually
# shapes — optimisation level, `-D`/`-U`, `-std=`, `-f*`, `-W*` — EXACTLY as
# the recipe wrote it, filtered through the SAME accepted-option set the
# driver cross-check already measures (driver_rejects_option), so an
# emcc-only `-f`/`-W` spelling this gate cannot honour is left out rather
# than handed to clang and read as a false red. Position-independent, like
# classify_inputs: no token's meaning depends on the one before it.
call_accepted_flags() {
    local argv="$1" tok
    while IFS= read -r -d '' tok; do
        case "$tok" in
            -O0|-O1|-O2|-O3|-Os|-Oz|-Ofast|-Og|-D*|-U*|-std=*|-f*|-W*) : ;;
            *) continue ;;
        esac
        driver_rejects_option "$tok" && continue
        printf '%s\0' "$tok"
    done < "$argv"
}

# THE DRIVER IS FED ONLY OPTIONS AND OPERANDS IT CAN OPEN. emcc's SPACED
# setting form `-s TOTAL_MEMORY=64MB` is documented and accepted; bare `-s` is
# a flag clang knows (strip), so the operand `TOTAL_MEMORY=64MB` reached the
# driver as an INPUT and clang answered `error: no such file or directory:
# 'TOTAL_MEMORY=64MB'`, which this function turned into `FAIL: the real
# compiler driver refused the recorded command line` — a FALSE RED on a recipe
# emcc builds fine (measured by a blind critic, 2026-09-21; the glued
# `-sTOTAL_MEMORY=64MB` is an unknown option and was already removed).
#
# The token to drop is MEASURED, never typed: the driver is run, and if it
# refuses, its own `no such file or directory: '<token>'` diagnostic names the
# operands it could not open. Those are dropped and the driver is re-run. A
# rule of the form "a non-option token that is not a file is an emcc setting"
# would have been wrong in the usual direction: `-x c web/unit.inc` has
# exactly that shape, and dropping `c` hands clang the unit as a LANGUAGE.
# Every dropped token is REPORTED on the `classifier: dropped=` line.
#
# With ONE exception, which is why this is a drop and not a silence: a refused
# operand whose suffix IS a C-family translation unit suffix is FAIL BY NAME.
# That is a typo in the recipe — emcc would refuse it too — and dropping it
# would let the gate examine one TU fewer than the recipe names and print OK.
#
# $1 = expanded argv, $2 = cwd, $3 = captured stdin TU, $4 = output list.
# Prints nothing on stdout; writes one ABSOLUTE path per line to $4, and
# appends each dropped token to CLASSIFIER_DROPPED.
driver_inputs() {
    local argv="$1" root="$2" stdin_tu="$3" out="$4"
    local tok lang file rc bad round=0 dropped_any t x_lang
    local -a keep=()
    local -a next=()
    while IFS= read -r -d '' tok; do
        case "$tok" in
            -?*) driver_rejects_option "$tok" && continue ;;
        esac
        keep+=("$tok")
    done < "$argv"
    while :; do
        ( cd "$root" && clang -m32 -fsyntax-only -c \
            -Werror=switch -Werror=comment -Werror=misleading-indentation \
            -### "${keep[@]}" ) >/dev/null 2>"$RUN/driver.err"
        rc=$?
        [ "$rc" -eq 0 ] && break
        # WHICH token the driver refused is MEASURED from its own diagnostic,
        # never guessed from a model of which options take an operand: `-x c`
        # and `-s TOTAL_MEMORY=64MB` are the same shape to any such model, and
        # dropping `c` from the first would hand clang the unit as a LANGUAGE.
        # The driver names the operand it could not open; that is the one that
        # is not a file.
        sed -n "s/.*error: no such file or directory: '\(.*\)'\$/\1/p" "$RUN/driver.err" \
            | sort -u > "$RUN/driver.missing"
        if ! [ -s "$RUN/driver.missing" ]; then
            echo "FAIL: the real compiler driver refused the recorded command line (exit $rc), so the gate cannot cross-check which arguments are translation units:" >&2
            sed 's/^/      /' "$RUN/driver.err" >&2
            return 1
        fi
        while IFS= read -r bad; do
            case "$bad" in
                *.c|*.C|*.cc|*.CC|*.cpp|*.CPP|*.cxx|*.CXX|*.c++)
                    echo "FAIL: the recipe hands the compiler '$bad', which names a translation unit that does not exist under the sandbox — the gate would examine one TU fewer than the recipe names, and the recipe itself would not build" >&2
                    return 1
                    ;;
            esac
            # The same rule, on the axis the SUFFIX cannot express. Round 6
            # keyed this exception on the C-family suffix alone, so `-x c
            # web/missing.inc -x none` — a unit the recipe names, emcc would
            # refuse, and this gate can never examine — was DROPPED and the
            # run printed `OK: examined 23`, rc 0 (measured by a blind critic,
            # 2026-09-21). Plant 2u already proves an EXISTING `-x c` unit is
            # examined; this is its missing twin. The language in effect is
            # read from the recorded argv the way the driver reads it.
            x_lang=$(xlang_for_token "$bad" ${keep[@]+"${keep[@]}"})
            if [ -n "$x_lang" ] && [ "$x_lang" != none ]; then
                echo "FAIL: the recipe hands the compiler '$bad' as a '-x $x_lang' translation unit, and it does not exist under the sandbox — the gate would examine one TU fewer than the recipe names, and the recipe itself would not build" >&2
                return 1
            fi
        done < "$RUN/driver.missing"
        next=()
        dropped_any=0
        for t in ${keep[@]+"${keep[@]}"}; do
            if grep -qxF -- "$t" "$RUN/driver.missing"; then
                dropped_any=1
                CLASSIFIER_DROPPED="$CLASSIFIER_DROPPED $t"
                continue
            fi
            next+=("$t")
        done
        if [ "$dropped_any" -eq 0 ]; then
            echo "FAIL: the real compiler driver refused the recorded command line (exit $rc) over operand(s) that are not on it, so the gate cannot cross-check which arguments are translation units:" >&2
            sed 's/^/      /' "$RUN/driver.err" >&2
            return 1
        fi
        keep=(${next[@]+"${next[@]}"})
        round=$((round + 1))
        if [ "$round" -gt 16 ]; then
            echo "FAIL: the driver cross-check dropped non-file operands 16 times and the driver still refuses the line:" >&2
            sed 's/^/      /' "$RUN/driver.err" >&2
            return 1
        fi
    done
    : > "$out"
    # TU_LANG_MAP is APPENDED, never truncated: it accumulates across every
    # recorded invocation, and sandbox_record_inputs truncates it once per
    # recipe run.
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

# Prints the `-x` language in effect for a token on a recorded command line,
# or nothing when no `-x` is active there. Args: $1 the token, $2.. the command
# line IN ORDER. Both spellings the driver accepts are read — `-x c` and the
# glued `-xc` — and `-x none` turns the language back off, exactly as clang
# documents. Nothing but the answer is printed.
xlang_for_token() {
    local want="$1" cur='' t pending=0
    shift
    for t in "$@"; do
        if [ "$pending" -eq 1 ]; then cur="$t"; pending=0; continue; fi
        case "$t" in
            -x)   pending=1; continue ;;
            -x?*) cur="${t#-x}"; continue ;;
        esac
        if [ "$t" = "$want" ]; then
            printf '%s' "$cur"
            return 0
        fi
    done
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

# #1232: $1 = a translation unit path, as recorded (absolute). Prints the
# accepted flags of the CALL that recorded it, one per NUL, or nothing if the
# TU has no recorded call (a header pulled in only by the parity scan, say —
# compile_tu falls back to CALL_FLAGS_ALL then). First call to report a TU
# wins, the same rule tu_language uses, which is what makes a TU compiled
# once under one call's own `-D` and again — unqualified — inside a later
# call's SOURCES examined under the call that actually shaped it.
call_flags_for_tu() {
    local tu="$1" d
    d=$(awk -F'\t' -v T="$tu" '$1 == T { print $2; exit }' "$TU_CALL_DIR_MAP" 2>/dev/null)
    [ -n "$d" ] && [ -f "$d/flags" ] && cat "$d/flags"
    return 0
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
# Either way the working tree is not reachable from the sandbox at all —
# PROVIDED the recipe is run from the sandbox, which is why
# `sandbox_record_inputs` cds there before invoking it rather than trusting the
# recipe's own `cd "$(dirname "$0")/.."` (round 6 trusted it, and a line placed
# BEFORE that cd wrote straight into the real src/ under a green gate; plants
# 2w and 2wp pin both sides of the cd).
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
    local sbx="$1" out="$2" recdir log rc root stdin_tu exp d argv cwdf createdf stdinf
    recdir="$sbx/.eigs-ilp32-rec"
    log="$sbx/.eigs-ilp32-recipe.log"
    rm -rf "$recdir"
    mkdir -p "$recdir" || return 1
    : > "$sbx/.eigs-ilp32-classifier-diff"
    : > "$TU_LANG_MAP"
    : > "$TU_CALL_DIR_MAP"
    CALL_FLAGS_ALL=()
    CLASSIFIER_DROPPED=''
    # The recipe runs FROM THE SANDBOX. Round 6 ran it from the GATE's cwd
    # ($REPO) and relied on the recipe's own `cd "$(dirname "$0")/.."` to put
    # it there, so the sandbox held for everything AFTER that line and nothing
    # before it: a recipe line writing `src/x.h` by relative path before the
    # `cd` landed in the REAL working tree with the gate green (measured by a
    # blind critic, 2026-09-21 — two files LANDED, `OK: examined 23`, rc 0),
    # while the header two screens up said the tree "is not reachable from the
    # sandbox at all". Plant 2w inserts after the `cd` and could not see it;
    # plant 2wp inserts before it and does. Subshell, so the gate's own cwd is
    # untouched for everything that follows.
    ( cd "$sbx" && EIGS_ILP32_REC_DIR="$recdir" \
        PATH="$STANDIN_BIN:$PATH" \
        bash "$sbx/web/build.sh" ) > "$log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL: the playground recipe exited $rc under the recording stand-in, so the gate cannot know what is compiled:" >&2
        sed 's/^/      /' "$log" >&2
        return 1
    fi
    CLASSIFIER_N_CALLS=0
    : > "$RUN/fs.raw"
    : > "$RUN/drv.raw"
    # EVERY recorded invocation, in the order the recipe made them. The two
    # derivations are taken per call — each call has its OWN cwd, its own
    # created-file set and its own stdin unit — and unioned across calls.
    for d in "$recdir"/call-*; do
        [ -d "$d" ] || continue
        argv="$d/argv"
        cwdf="$d/cwd"
        createdf="$d/created"
        stdinf="$d/stdin.c"
        [ -f "$argv" ] || continue
        CLASSIFIER_N_CALLS=$((CLASSIFIER_N_CALLS + 1))
        exp="$d/argv-expanded"
        root=$(cat "$cwdf" 2>/dev/null)
        [ -n "$root" ] || root="$sbx"
        expand_response_files "$argv" "$root" "$exp" || return 1
        # Existence, not size (Astra rank 9, #1232 item 12): `-x c -` with
        # EMPTY stdin is a valid empty translation unit, and real wasm clang
        # accepts it. The stand-in `cat > "$d/stdin.c"` always creates the
        # file when `-` is in argv, empty or not; `-s` (nonzero size) read
        # that as "nothing was captured" and refused a recipe the real
        # compiler builds fine.
        stdin_tu=''
        [ -f "$stdinf" ] && stdin_tu="$stdinf"
        local stdin_asked=0 t
        while IFS= read -r -d '' t; do
            [ "$t" = "-" ] && stdin_asked=1
        done < "$exp"
        if [ -z "$stdin_tu" ] && [ "$stdin_asked" -eq 1 ]; then
            echo "FAIL: the recipe handed the compiler a translation unit on standard input and nothing was captured — the gate would examine one TU fewer than emcc compiles" >&2
            return 1
        fi
        classify_inputs "$exp" "$root" "$createdf" "$stdin_tu" > "$d/fs.inputs"
        cat "$d/fs.inputs" >> "$RUN/fs.raw"
        driver_inputs "$exp" "$root" "$stdin_tu" "$d/drv.inputs" || return 1
        cat "$d/drv.inputs" >> "$RUN/drv.raw"
        # #1232: this call's own flags, and which TU each derivation charges
        # to it. First call to name a TU wins (append-only, first-match at
        # lookup — the same rule TU_LANG_MAP uses), so a TU compiled once
        # under this call's own `-D`/`-O` and again inside a LATER call's
        # unqualified SOURCES is still examined under the call that shaped
        # it.
        local p
        while IFS= read -r p; do
            [ -n "$p" ] && printf '%s\t%s\n' "$p" "$d" >> "$TU_CALL_DIR_MAP"
        done < "$d/fs.inputs"
        while IFS= read -r p; do
            [ -n "$p" ] && printf '%s\t%s\n' "$p" "$d" >> "$TU_CALL_DIR_MAP"
        done < "$d/drv.inputs"
        call_accepted_flags "$exp" > "$d/flags"
        local cf cf_seen cf_old
        while IFS= read -r -d '' cf; do
            cf_seen=0
            for cf_old in ${CALL_FLAGS_ALL[@]+"${CALL_FLAGS_ALL[@]}"}; do
                [ "$cf_old" = "$cf" ] && { cf_seen=1; break; }
            done
            [ "$cf_seen" -eq 0 ] && CALL_FLAGS_ALL+=("$cf")
        done < "$d/flags"
    done
    if [ "$CLASSIFIER_N_CALLS" -eq 0 ]; then
        echo "FAIL: the playground recipe completed without ever invoking the compiler — there is no argv to examine, and an unexamined recipe is not a clean one" >&2
        sed 's/^/      /' "$log" >&2
        return 1
    fi
    sort -u "$RUN/fs.raw" > "$RUN/fs.inputs"
    sort -u "$RUN/drv.raw" > "$RUN/drv.inputs"
    sort -u "$RUN/fs.inputs" "$RUN/drv.inputs" > "$out"
    CLASSIFIER_N_FS=$(grep -c . "$RUN/fs.inputs")
    CLASSIFIER_N_DRV=$(grep -c . "$RUN/drv.inputs")
    CLASSIFIER_DROPPED=${CLASSIFIER_DROPPED# }
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
# files it was HANDED and how many conditional lines it matched, and BOTH are
# cross-checked against an independent `grep -c` over the same list. A
# disagreement is FAIL BY NAME.
#
# THE FILE COUNT IS BY ENUMERATION, NOT BY `FNR == 1`. Round 5 counted a file
# as seen when awk reached its first record — which an EMPTY file never has.
# A `.c` the recipe's own first call produced with `-o` and its second call
# compiled is empty, in the population, and compiles clean; the gate answered
# `FAIL: the conditional scan opened 45 of the 46 files it enumerated — the
# tested-macro population shrank silently`, which is loud and wrong (measured
# by a blind critic, 2026-09-21). awk now reports `ARGC - 1`, the files it was
# HANDED, so an empty translation unit is examined and counted like any other.
# The check is not vacuous: it still catches an argument list that reaches awk
# with a different shape than bash enumerated, and a file awk cannot OPEN is
# caught by awk's own status, which is checked.
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
        END { print (ARGC - 1) " " nlines + 0 > "/dev/stderr" }
    ' "${scan[@]}" 2>"$RUN/tested.counts" | sort -u > "$out"
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        echo "FAIL: the preprocessor-conditional scan exited non-zero, so the tested-macro population is a partial one:" >&2
        sed 's/^/      /' "$RUN/tested.counts" >&2
        return 1
    fi
    nseen=$(awk 'END { print $1 + 0 }' "$RUN/tested.counts")
    nlines=$(awk 'END { print $2 + 0 }' "$RUN/tested.counts")
    if [ "$nseen" -ne "$nfiles" ]; then
        echo "FAIL: the conditional scan was handed $nseen of the $nfiles files it enumerated — the tested-macro population shrank silently" >&2
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
    # #1232: this probe compiles the population's OWN system headers under
    # the candidate reconciliation — it must see the same call flags the
    # target/host worlds were derived with, or it measures a header's
    # compileability under a world the real recipe never builds.
    base+=(${CALL_FLAGS_ALL[@]+"${CALL_FLAGS_ALL[@]}"})
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
    # #1232: this re-derivation must carry CALL_FLAGS_ALL too, or it disagrees
    # with BOTH target.dM and host.dM (macro_parity_init derived both of those
    # WITH the call's flags) — __OPTIMIZE__ would be present in the target
    # world and absent here, a FALSE mismatch this verify step would then
    # blame on the code rather than on its own incomplete re-derivation.
    derive_predefines "$eff" host ${flags[@]+"${flags[@]}"} ${CALL_FLAGS_ALL[@]+"${CALL_FLAGS_ALL[@]}"} || return 1
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

    # #1232: the recorded call's own flags (CALL_FLAGS_ALL) shape BOTH derived
    # worlds, not only the compile — the live recipe's -O2 defines
    # __OPTIMIZE__ in the target's real macro world, and a derivation that
    # never sees -O2 derives a world the real build does not have. Passed to
    # BOTH sides identically: a flag that changes something in only one world
    # (there is none among -O/-D/-U/-std/-f/-W today) would surface as an
    # ordinary NAME difference below and get reconciled like any other.
    derive_predefines "$tgt" target ${CALL_FLAGS_ALL[@]+"${CALL_FLAGS_ALL[@]}"} || return 1
    derive_predefines "$hst" host ${CALL_FLAGS_ALL[@]+"${CALL_FLAGS_ALL[@]}"} || return 1
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
    # #1232: this probe's world must match target.dM/host.dM's — both were
    # derived WITH the recorded call's flags.
    if ! header_probe_ok "${nameflags[@]}" ${CALL_FLAGS_ALL[@]+"${CALL_FLAGS_ALL[@]}"}; then
        # ROUND 6: the SAME discriminator as the availability probe, applied
        # one stage later. Round 5 turned ANY refusal here into a SKIP, and a
        # blind critic broke the reconciliation derivation on LINUX and got
        # `SKIP:` + exit 0 + `TOTAL=0` out of it — the gate's own derivation
        # being wrong read as "this runner has nothing to say". Only the SDK's
        # own refusal of the architecture may skip; a C library that refuses
        # for any OTHER reason is the gate being wrong, and that is a FAIL.
        #
        # This is the stage macos-latest actually reaches: its availability
        # probe PASSES (the SDK compiles a 32-bit TU against its own headers),
        # and the refusal arrives only once the reconciliation has replaced
        # `__i386__`/`__APPLE__` with the target's world — which is the
        # reconciliation doing its job, and the SDK answering
        # `sys/cdefs.h:1068: error: Unsupported architecture` (measured in CI,
        # 2026-09-21). So the match is on the diagnostic, not on the stage.
        #
        # THE CONTROL RUNS FIRST, in the LIVE path and not only in --selftest:
        # round 5's control 5rc was a --selftest case, and the section runs
        # --selftest only in the NON-skip branch, so on the very run that
        # skipped, the control never executed. The control is this same probe
        # with NO reconciliation — it decides whether these headers preprocess
        # at 32 bits at all, which is what makes a refusal attributable. It
        # runs on every branch and its verdict is printed with the skip or the
        # failure; it does not get a VOTE on the skip, because the thing that
        # decides a skip is the SDK saying the words, and a control that
        # disagreed would only turn a capability absence into a red lane on a
        # runner this gate has nothing to say about.
        cp "$RUN/header_probe.err" "$RUN/header_probe.reconciled.err"
        local control_ok=0 control_says
        header_probe_ok && control_ok=1
        if [ "$control_ok" -eq 1 ]; then
            control_says='control: these same headers DO preprocess at 32 bits without the reconciliation, so what this toolchain refuses is the target macro world itself'
        else
            control_says='control: these same headers do NOT preprocess at 32 bits without the reconciliation either'
        fi
        if grep -qE "$ILP32_SDK_REFUSAL_RE" "$RUN/header_probe.reconciled.err"; then
            MACRO_PARITY_SKIP_REASON=$(printf '%s\n%s\n' "$(cat "$RUN/header_probe.reconciled.err")" "$control_says")
        elif [ "$control_ok" -eq 1 ]; then
            echo "FAIL: this C library's own headers preprocess at 32 bits UNRECONCILED (control) and REFUSE the wasm32 target's macro world this gate derived — and NOT because the SDK refuses the architecture, so the derivation is wrong, and a wrong derivation is a broken gate, not a runner to skip:" >&2
            sed 's/^/      /' "$RUN/header_probe.reconciled.err" >&2
        else
            echo "FAIL: this C library's own headers do not preprocess at 32 bits even WITHOUT the reconciliation (control), although the availability probe passed — the gate's apparatus is inconsistent with itself:" >&2
            sed 's/^/      /' "$RUN/header_probe.err" >&2
            echo "      and under the reconciliation:" >&2
            sed 's/^/      /' "$RUN/header_probe.reconciled.err" >&2
        fi
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
    local out st inc lang cf
    local -a xlang=() callflags=()
    inc="-Isrc"
    [ -n "$extra_i" ] && inc="-I$extra_i -Isrc"
    lang=$(tu_language "$tu")
    [ -n "$lang" ] && xlang=(-x "$lang")
    # #1232: this TU's OWN call's accepted flags (optimisation level, -D/-U,
    # -std=, -f*, -W*, as recorded) — never discarded. The recorded call is
    # the authority; CALL_FLAGS_ALL (every recorded call's flags, unioned) is
    # the fallback for a TU with no recorded call of its own (a header the
    # parity scan pulled in, not a compiled TU).
    while IFS= read -r -d '' cf; do callflags+=("$cf"); done < <(call_flags_for_tu "$tu")
    [ "${#callflags[@]}" -eq 0 ] && callflags=(${CALL_FLAGS_ALL[@]+"${CALL_FLAGS_ALL[@]}"})
    # Status captured DIRECTLY. $? after a pipeline is the last stage.
    # Flag literals (not $VAR) so tools/werror_switch_check.sh can see them.
    # -c is load-bearing for that recognizer; -fsyntax-only is the actual work.
    # $MACRO_PARITY_FLAGS is DERIVED (see macro_parity_init) — the target's
    # predefines minus the host's, computed, never typed. $callflags is the
    # recipe's OWN recorded flags for this TU's call (issue #1232): a
    # duplicate -D of an identical value is harmless; a real divergence
    # (this TU's call carries its own -D the shared SOURCES call does not)
    # is exactly what must reach the compile, so it is appended LAST.
    out=$(clang -m32 -fsyntax-only -c \
        -Werror=switch -Werror=comment -Werror=misleading-indentation \
        -isystem "$stubdir" -isystem /usr/include/x86_64-linux-gnu \
        $inc \
        -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_MODEL=0 -DEIGENSCRIPT_EXT_DB=0 \
        ${MACRO_PARITY_FLAGS[@]+"${MACRO_PARITY_FLAGS[@]}"} \
        -DEIGENSCRIPT_VERSION="\"$EIGS_VERSION\"" \
        ${callflags[@]+"${callflags[@]}"} \
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
# ONLY THE SDK'S OWN REFUSAL MAY SKIP. Round 5 turned EVERY probe failure into
# a SKIP that exited 0, and a blind critic reached that branch four ways on
# THIS Linux box (2026-09-21): no `clang` on PATH, the gate's own
# `gnu/stubs-32.h` stub deleted, `-isystem /usr/include/x86_64-linux-gnu`
# pointing nowhere, and a broken reconciliation derivation. Each printed
# `SKIP:` and exited 0, the section contributed `TOTAL=0`, and nothing counted
# it — a gate that stopped measuring read exactly like a gate that measured.
# Every one of those is the GATE'S OWN APPARATUS breaking, not a capability
# this runner lacks, so every one of them is now FAIL BY NAME. The single
# thing that may skip is the one this gate genuinely cannot stand in for: a C
# library with no 32-bit target for its own headers, which says so in its own
# words — the macOS SDK's `sys/cdefs.h: error: Unsupported architecture`. That
# diagnostic is MATCHED and PRINTED, and the runner counts the skip.
#
# BOTH wordings the SDK actually emits are matched. Measured on macos-latest at
# 1b5c64d (the CI log of this PR's own [99i3] block): ONE probe produced
#     .../MacOSX.sdk/usr/include/sys/cdefs.h:1068:2: error: Unsupported architecture
#     .../MacOSX.sdk/usr/include/machine/_types.h:36:2: error: architecture not supported
# in the same diagnostic. Round 6 matched only the first, so a header or SDK
# reorder that left only the SECOND would have turned macos-latest into a red
# lane by name ("NOT because the SDK refuses the architecture") — a gate going
# red for a reason unrelated to its claim (a blind critic, 2026-09-21). Both
# phrasings are the same claim by the same vendor; neither appears in any
# Linux system header on the dev box or in clang's resource directory (grep:
# 0 hits), so widening here does not admit a non-SDK break (mechanical-gates
# §13: broad enough to see the real shape, anchored enough not to cry wolf).
# Control, pinned by self-test plant 5sg: glibc's "You need a ISO C ..." must
# still be a FAIL.
ILP32_SDK_REFUSAL_RE='error:[ \t]*(Unsupported architecture|architecture not supported)'
# The multiarch system include directory the gate compiles against. A variable
# because the availability verdict has to be able to say that IT is what is
# missing, and because self-test plant 5b3 probes with one that does not exist.
SYS_INCLUDE_DIR=/usr/include/x86_64-linux-gnu

# $1 = the stub include dir to probe with, $2 = the system include dir. Prints
# the toolchain's own words on failure and nothing on success; status is the
# verdict. Taking both directories as arguments is what makes the arms
# testable: plant 5s probes with a stub whose <stdlib.h> answers the SDK's own
# refusal, 5b2 with a stub that has lost its `gnu/stubs-32.h`, and 5b3 with a
# system include directory that does not exist.
ilp32_capability_probe() {
    local stubdir="$1" sysdir="$2" out
    printf '%s\n' '#include <stdlib.h>' '#include <stdio.h>' \
                  'int eigs_ilp32_probe(void) { return 0; }' > "$stubdir/probe_avail.c"
    # The -Werror= trio is not load-bearing for a three-line probe; it is here
    # because tools/werror_switch_check.sh audits every compile line in this
    # script by SOURCE TEXT, and an audited line without them is a violation.
    if out=$(clang -m32 -fsyntax-only -c \
            -Werror=switch -Werror=comment -Werror=misleading-indentation \
            -isystem "$stubdir" -isystem "$sysdir" \
            "$stubdir/probe_avail.c" 2>&1); then
        return 0
    fi
    printf '%s\n' "$out"
    return 1
}

# $1 = stub dir, $2 = system include dir, $3 = the probe's own diagnostic.
# Status 0 = this is the SDK refusing the architecture: a capability absence,
# a SKIP by name, printed on STDOUT because the runner reads it and counts it.
# Status 1 = the gate's apparatus is broken: a FAIL by name on STDERR, naming
# WHICH piece. Every branch prints the diagnostic it decided on.
ilp32_availability_verdict() {
    local stubdir="$1" sysdir="$2" diag="$3"
    if grep -qE "$ILP32_SDK_REFUSAL_RE" <<<"$diag"; then
        echo "SKIP: this toolchain's C library has no 32-bit target for its own headers — it refuses the architecture in its own words below, so the playground's 32-bit shape was NOT checked"
        printf '%s\n' "$diag" | sed 's/^/      /'
        return 0
    fi
    if ! [ -f "$stubdir/gnu/stubs-32.h" ]; then
        echo "FAIL: the gate's own <gnu/stubs-32.h> stub is missing from $stubdir, so the availability probe measured the GATE'S APPARATUS, not this toolchain — that is a broken gate, not a runner without a 32-bit target:" >&2
    elif ! [ -f "$stubdir/emscripten.h" ]; then
        echo "FAIL: the gate's own <emscripten.h> stub is missing from $stubdir, so the availability probe measured the GATE'S APPARATUS, not this toolchain:" >&2
    elif ! [ -d "$sysdir" ]; then
        echo "FAIL: the gate's system include directory $sysdir does not exist on this box, so the availability probe measured the GATE'S APPARATUS, not this toolchain — fix the directory the gate compiles against:" >&2
    elif grep -qF 'command not found' <<<"$diag"; then
        echo "FAIL: the gate could not run a 32-bit compile at all — the compiler it invokes is not on PATH, so nothing was measured:" >&2
    else
        echo "FAIL: the 32-bit availability probe failed for a reason that is NOT this toolchain refusing the architecture, so it is the gate's own apparatus and not a capability absence — only an SDK that says '$ILP32_SDK_REFUSAL_RE' may skip:" >&2
    fi
    printf '%s\n' "$diag" | sed 's/^/      /' >&2
    return 1
}

if ! avail_err=$(ilp32_capability_probe "$STUB" "$SYS_INCLUDE_DIR"); then
    if ilp32_availability_verdict "$STUB" "$SYS_INCLUDE_DIR" "$avail_err"; then
        exit 0
    fi
    exit 1
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
echo "classifier: $CLASSIFIER_N_CALLS call(s) recorded"
echo "classifier: $CLASSIFIER_N_FS input(s) by suffix+filesystem, $CLASSIFIER_N_DRV by the driver derivation, $N_LIVE_TUS in the union examined"
echo "classifier: dropped=${CLASSIFIER_DROPPED:-none}"
# #1232: the recorded call's own flags, applied to both the macro-world
# derivation below and every TU compile (compile_tu, via call_flags_for_tu /
# CALL_FLAGS_ALL) — never discarded after being recorded. "per call" because
# a TU is examined under the flags of the call that shaped it, not a single
# flat list; the live recipe issues one call, so this count IS that call's
# accepted-option population.
echo "classifier: flags=${#CALL_FLAGS_ALL[@]} per call"
# The self-test's argv_plant() asserts CLASSIFIER_DROPPED relative to this
# baseline (item 11, Astra rank 4): a hardcoded "must be empty" would fail
# every unrelated plant the moment the LIVE recipe itself legitimately drops
# an operand (a spaced `-s X=Y`, say), which is a false red in the plant, not
# a finding about it.
LIVE_DROPPED="$CLASSIFIER_DROPPED"

if ! macro_parity_init "$LIVE_TUS"; then
    # The ONLY skip left at this stage, and the same one the availability
    # probe names: the SDK refuses the architecture once its own arch macros
    # are replaced by the target's. Everything else macro_parity_init already
    # reported as a FAIL by name, with its control decided first.
    if [ -n "$MACRO_PARITY_SKIP_REASON" ]; then
        echo "SKIP: this toolchain's C library has no 32-bit target for its own headers in the wasm32 target's macro world — it refuses the architecture in its own words below, so the playground's 32-bit shape was NOT checked"
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
# $8 a token that must appear in `classifier: dropped=` (empty = NOTHING may
# be dropped from the driver call). Every plant asserts it, so a drop rule
# that starts eating operands shows up on the plant next door.
# The scratch recipe is read from "$WORK/$key.sh".
argv_plant() {
    local key="$1" label="$2" want_delta="$3" want_present="$4" want_absent="$5" tu_content="${6:-}" want_diff="${7:-}" want_dropped="${8:-}"
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
    if [ -z "$want_dropped" ]; then
        # Relative to the LIVE recipe's OWN baseline (item 11, Astra rank 4),
        # not to "empty": every argv_plant scratch recipe is $BUILD_SH plus
        # one inserted line, so it inherits whatever the live recipe itself
        # already drops. Hardcoding "must be empty" here made an unrelated
        # plant fail the moment the live recipe legitimately drops an
        # operand (a spaced `-s X=Y`, measured through chunk.sh on plant
        # r5-s-spaced-VFlD) — a false red in the plant, not a finding.
        if [ "$CLASSIFIER_DROPPED" != "${LIVE_DROPPED:-}" ]; then
            echo "selftest FAIL: $label — the driver cross-check dropped operand(s) beyond the live recipe's own baseline ('${LIVE_DROPPED:-}'): $CLASSIFIER_DROPPED"
            fails=1
            return
        fi
    elif ! grep -qF -- "$want_dropped" <<<"$CLASSIFIER_DROPPED"; then
        echo "selftest FAIL: $label — '$want_dropped' was not dropped from the driver call; dropped='$CLASSIFIER_DROPPED'"
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
    1 ".eigs-ilp32-rec/call-0001/stdin.c" "" "" ""

# 12es: plant 2i's EMPTY twin (#1232 item 12, Astra rank 9). `-x c -` with
# NOTHING piped is a valid empty translation unit — real wasm clang accepts
# it — but the stand-in's `cat > "$d/stdin.c"` creates the file regardless,
# empty or not, and `[ -s "$stdinf" ]` (nonzero SIZE) read an empty capture as
# "nothing was captured" and refused a recipe the real compiler builds fine.
# Same recipe shape as 2i, stdin redirected from /dev/null instead of a
# planted source.
sed 's|^\( *\)-o web/dist/eigs\.js < web/eigs_ilp32_plant_2i\.c$|\1-o web/dist/eigs.js < /dev/null|' \
    "$WORK/2i.sh" > "$WORK/12es.sh"
if cmp -s "$WORK/2i.sh" "$WORK/12es.sh"; then
    echo "selftest FAIL: plant 12es was a no-op — the stdin redirection was not retargeted to /dev/null"
    fails=1
elif ! sandbox_prepare "$WORK/sbx-12es" "$WORK/12es.sh" 2>"$WORK/12es.prep.err"; then
    echo "selftest FAIL: plant 12es could not be staged:"
    sed 's/^/      /' "$WORK/12es.prep.err"
    fails=1
elif ! sandbox_record_inputs "$WORK/sbx-12es" "$WORK/12es.tus" 2>"$WORK/12es.err"; then
    echo "selftest FAIL: plant 12es — a recipe piping EMPTY stdin to a -x c - unit was refused as if nothing were captured:"
    sed 's/^/      /' "$WORK/12es.err"
    fails=1
else
    n=$(grep -c . "$WORK/12es.tus")
    stdin_capture="$WORK/sbx-12es/.eigs-ilp32-rec/call-0001/stdin.c"
    if [ "$n" -ne $((N_LIVE_TUS + 1)) ]; then
        echo "selftest FAIL: plant 12es moved the population by $((n - N_LIVE_TUS)), want 1 — the empty stdin TU was not counted"
        fails=1
    elif ! [ -f "$stdin_capture" ]; then
        echo "selftest FAIL: plant 12es — the stdin capture file does not exist, so this plant proves nothing about emptiness"
        fails=1
    elif [ -s "$stdin_capture" ]; then
        echo "selftest FAIL: plant 12es — the stdin capture is not empty, so this plant does not test the empty case"
        fails=1
    elif ! grep -qx "$stdin_capture" "$WORK/12es.tus"; then
        echo "selftest FAIL: plant 12es — the empty stdin TU is not in the derived population:"
        sed 's/^/      /' "$WORK/12es.tus"
        fails=1
    elif ! compile_tu "$stdin_capture" "" "$STUB" 2>"$WORK/12es.compile.err"; then
        echo "selftest FAIL: plant 12es — the empty stdin TU was examined but did not compile clean, so it was not treated as a valid empty unit:"
        sed 's/^/      /' "$WORK/12es.compile.err"
        fails=1
    else
        echo "selftest ok: plant 12es empty stdin (-x c - with nothing piped) is examined and counted, not rejected as an uncaptured input"
    fi
fi

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

# ---- the MULTI-CALL plants (2c, 2ca, 2cz, 2b) ----------------------------
# Round 5's stand-in wrote its records with `>`, so only the LAST invocation
# survived and every unit compiled by an earlier call was outside the
# population — the gate printed `OK: examined 23` on a recipe whose first call
# compiled a planted `#error` unit (measured by a blind critic, 2026-09-21).
# Compile-then-link is the canonical build shape.

# 2c: the critic's own two-call shape — a `-c` compile of a planted unit, then
# the live link line with its `.o` added.
awk '/^emcc / { print "emcc -Werror=switch -Werror=comment -Werror=misleading-indentation -c web/eigs_ilp32_plant_2c.c -o web/dist/eigs_ilp32_plant_2c.o" }
     { print }
     /^[ \t]*"\$\{SOURCES\[@\]\}"[ \t]*\\[ \t]*$/ { print "    web/dist/eigs_ilp32_plant_2c.o \\" }' \
    "$BUILD_SH" > "$WORK/2c.sh"
argv_plant 2c "plant 2c a TU compiled by an EARLIER invocation than the link line is examined (24 of 24)" \
    1 "web/eigs_ilp32_plant_2c.c" "" '#error EIGS_ILP32_PLANT_2C' ""

# 2ca: the PURE compile-then-link shape — one `-c` call per unit and then a
# link of the objects. Round 5 recorded the link call alone, whose inputs are
# all `.o`, so the population was ZERO; the floor caught that one loudly,
# which is why last-wins looked safe. Here the assertion is the count of
# CALLS as well as the population, because that is the fact that was missing.
# The recipe is built FROM the live one — a `-c` call per unit inserted before
# the live compile line, whose SOURCES expansion is replaced by the objects —
# so the link step is the recipe's own line and every generated compile line
# carries the -Werror trio tools/werror_switch_check.sh requires of one.
sed "s|^$LIVE_SBX/||" "$LIVE_TUS" > "$WORK/2ca.srcs"
awk -v SRCS="$WORK/2ca.srcs" '
    /^emcc / && !ins {
        n = 0
        while ((getline s < SRCS) > 0) {
            if (s == "") continue
            n++
            printf "emcc -Werror=switch -Werror=comment -Werror=misleading-indentation -c %s -o web/dist/eigs_ilp32_2ca_%03d.o\n", s, n
        }
        ins = 1
    }
    /^[ \t]*"\$\{SOURCES\[@\]\}"[ \t]*\\[ \t]*$/ { print "    web/dist/eigs_ilp32_2ca_*.o \\"; next }
    { print }' "$BUILD_SH" > "$WORK/2ca.sh"
if ! sandbox_prepare "$WORK/sbx-2ca" "$WORK/2ca.sh" 2>"$WORK/2ca.prep.err"; then
    echo "selftest FAIL: plant 2ca could not be staged:"
    sed 's/^/      /' "$WORK/2ca.prep.err"
    fails=1
elif ! sandbox_record_inputs "$WORK/sbx-2ca" "$WORK/2ca.tus" 2>"$WORK/2ca.err"; then
    echo "selftest FAIL: plant 2ca — a compile-then-link recipe recorded nothing:"
    sed 's/^/      /' "$WORK/2ca.err"
    fails=1
elif [ "$CLASSIFIER_N_CALLS" -ne $((N_LIVE_TUS + 1)) ]; then
    echo "selftest FAIL: plant 2ca — the recipe made $((N_LIVE_TUS + 1)) compiler invocations and the recorder kept $CLASSIFIER_N_CALLS"
    fails=1
elif [ "$(grep -c . "$WORK/2ca.tus")" -ne "$N_LIVE_TUS" ]; then
    echo "selftest FAIL: plant 2ca — a compile-then-link recipe over $N_LIVE_TUS units derived a population of $(grep -c . "$WORK/2ca.tus")"
    sed 's/^/      /' "$WORK/2ca.tus"
    fails=1
else
    echo "selftest ok: plant 2ca a pure compile-then-link recipe records $CLASSIFIER_N_CALLS call(s) and examines $N_LIVE_TUS TUs (not 0)"
fi

# 2cz: a recipe that never invokes the compiler at all. `examined 0` is the
# same class as plant 2, one layer earlier: a recipe nobody compiled is not a
# clean recipe.
awk '/^emcc / { print "echo eigs_ilp32_plant_2cz: this recipe compiles nothing"; skip = 1 }
     skip { if ($0 ~ /^[ \t]*-o web\/dist\/eigs\.js[ \t]*$/) skip = 0; next }
     { print }' "$BUILD_SH" > "$WORK/2cz.sh"
if cmp -s "$BUILD_SH" "$WORK/2cz.sh"; then
    echo "selftest FAIL: plant 2cz was a no-op — the compile line was not removed from the scratch recipe"
    fails=1
elif ! sandbox_prepare "$WORK/sbx-2cz" "$WORK/2cz.sh" 2>"$WORK/2cz.prep.err"; then
    echo "selftest FAIL: plant 2cz could not be staged:"
    sed 's/^/      /' "$WORK/2cz.prep.err"
    fails=1
elif sandbox_record_inputs "$WORK/sbx-2cz" "$WORK/2cz.tus" 2>"$WORK/2cz.err"; then
    echo "selftest FAIL: plant 2cz (a recipe with ZERO compiler invocations) was accepted — an unexamined recipe is not a clean one"
    fails=1
elif grep -q 'without ever invoking the compiler' "$WORK/2cz.err"; then
    echo "selftest ok: plant 2cz a recipe with zero compiler invocations is FAIL by name"
else
    echo "selftest FAIL: plant 2cz went red for the wrong reason:"
    sed 's/^/      /' "$WORK/2cz.err"
    fails=1
fi

# 2b: an EMPTY translation unit, produced by one call's own `-o` and compiled
# by the next. Round 5 counted files in the conditional scan with awk's
# `FNR == 1`, which an empty file never reaches, so the gate answered `the
# tested-macro population shrank silently` — loud, and wrong (measured by a
# blind critic, 2026-09-21). An empty TU compiles clean and must be examined
# and COUNTED like any other. Two units join the population here: the `-E`
# input and the empty output it names.
awk '/^emcc / { print "printf '"'"'int eigs_ilp32_plant_2b(void);\\n'"'"' > web/eigs_ilp32_plant_2b_src.c"
                print "emcc -Werror=switch -Werror=comment -Werror=misleading-indentation -E web/eigs_ilp32_plant_2b_src.c -o web/eigs_ilp32_plant_2b_gen.c" }
     { print }
     /^SOURCES=\(/ { print "    web/eigs_ilp32_plant_2b_gen.c" }' \
    "$BUILD_SH" > "$WORK/2b.sh"
if ! sandbox_prepare "$WORK/sbx-2b" "$WORK/2b.sh" 2>"$WORK/2b.prep.err"; then
    echo "selftest FAIL: plant 2b could not be staged:"
    sed 's/^/      /' "$WORK/2b.prep.err"
    fails=1
elif ! sandbox_record_inputs "$WORK/sbx-2b" "$WORK/2b.tus" 2>"$WORK/2b.err"; then
    echo "selftest FAIL: plant 2b — the two-call recipe recorded nothing:"
    sed 's/^/      /' "$WORK/2b.err"
    fails=1
elif ! grep -qx "$WORK/sbx-2b/web/eigs_ilp32_plant_2b_gen.c" "$WORK/2b.tus"; then
    echo "selftest FAIL: plant 2b — the empty generated unit the second call compiles is NOT in the derived population:"
    sed 's/^/      /' "$WORK/2b.tus"
    fails=1
elif [ -s "$WORK/sbx-2b/web/eigs_ilp32_plant_2b_gen.c" ]; then
    echo "selftest FAIL: plant 2b was a no-op — the generated unit is not empty, so the empty-file case was never exercised"
    fails=1
elif [ "$(grep -c . "$WORK/2b.tus")" -ne $((N_LIVE_TUS + 2)) ]; then
    echo "selftest FAIL: plant 2b moved the population to $(grep -c . "$WORK/2b.tus"), want $((N_LIVE_TUS + 2)) (the -E input and the empty unit it produced)"
    fails=1
elif ! tested_macros "$WORK/2b.tus" "$WORK/2b.names" 2>"$WORK/2b.scan.err"; then
    echo "selftest FAIL: plant 2b — an EMPTY translation unit in the population broke the conditional scan:"
    sed 's/^/      /' "$WORK/2b.scan.err"
    fails=1
elif ! examine_tus "$WORK/2b.tus" "" "$STUB" "$TU_FLOOR" >"$WORK/2b.examine.out" 2>&1; then
    echo "selftest FAIL: plant 2b — an EMPTY translation unit was not examined clean:"
    sed 's/^/      /' "$WORK/2b.examine.out"
    fails=1
else
    echo "selftest ok: plant 2b an empty TU produced by one call and compiled by the next is examined and counted ($(sed -n 's/^OK: //p' "$WORK/2b.examine.out"))"
fi

# 9e: #1232 item 9 (Astra rank 2, "2-empp-conditional") — a recipe line
# reaching `em++`, not `emcc`. Round 6 shimmed only `emcc`, so
# `command -v em++` found nothing on this box (no emsdk) and a conditional
# recipe line silently skipped: the gate reported the recipe clean while a
# box that DOES have em++ (real CI with emsdk, or a future local install)
# would compile — and could fail on — a TU this gate never saw. Same
# multi-call shape as plant 2c (a compile-then-link .o reference), so the
# only new variable is the driver name.
awk '/^emcc / { print "if command -v em++ >/dev/null; then em++ -c web/eigs_ilp32_plant_9e.c -o web/dist/eigs_ilp32_plant_9e.o; fi" }
     { print }
     /^[ \t]*"\$\{SOURCES\[@\]\}"[ \t]*\\[ \t]*$/ { print "    web/dist/eigs_ilp32_plant_9e.o \\" }' \
    "$BUILD_SH" > "$WORK/9e.sh"
argv_plant 9e "plant 9e a recipe line reaching em++ (not only emcc) is recorded and its TU examined (24 of 24)" \
    1 "web/eigs_ilp32_plant_9e.c" "" '#error EIGS_ILP32_PLANT_9E' ""

# ---- the DRIVER-OPERAND plants (3s, 3sj, 3st) ----------------------------
# emcc's spaced setting form was a FALSE RED: bare `-s` is clang's strip flag,
# so `TOTAL_MEMORY=64MB` reached the driver as an input it could not open and
# the gate reported `the real compiler driver refused the recorded command
# line` on a recipe emcc builds (measured by a blind critic, 2026-09-21).
awk '{ print } /^[ \t]*"\$\{SOURCES\[@\]\}"[ \t]*\\[ \t]*$/ { print "    -s TOTAL_MEMORY=64MB \\" }' \
    "$BUILD_SH" > "$WORK/3s.sh"
argv_plant 3s "plant 3s emcc's spaced setting form is dropped from the driver call and reported, not a red (23 of 23)" \
    0 "" "" "" "" "TOTAL_MEMORY=64MB"

awk '{ print } /^[ \t]*"\$\{SOURCES\[@\]\}"[ \t]*\\[ \t]*$/ { print "    -sTOTAL_MEMORY=64MB \\" }' \
    "$BUILD_SH" > "$WORK/3sj.sh"
argv_plant 3sj "control 3sj the glued setting form is an unknown option and needs no drop (23 of 23)" \
    0 "" "" "" "" ""

# 3st: the other direction. A `.c` token naming no existing file is a typo the
# recipe itself would not survive, so it is FAIL BY NAME and never a drop.
awk '{ print } /^[ \t]*"\$\{SOURCES\[@\]\}"[ \t]*\\[ \t]*$/ { print "    web/eigs_ilp32_plant_3st_missing.c \\" }' \
    "$BUILD_SH" > "$WORK/3st.sh"
if ! sandbox_prepare "$WORK/sbx-3st" "$WORK/3st.sh" 2>"$WORK/3st.prep.err"; then
    echo "selftest FAIL: plant 3st could not be staged:"
    sed 's/^/      /' "$WORK/3st.prep.err"
    fails=1
elif sandbox_record_inputs "$WORK/sbx-3st" "$WORK/3st.tus" 2>"$WORK/3st.err"; then
    echo "selftest FAIL: plant 3st (a .c token naming no existing file) was accepted — a TU the recipe names and the gate cannot examine"
    fails=1
elif grep -q 'names a translation unit that does not exist' "$WORK/3st.err"; then
    echo "selftest ok: plant 3st a .c token naming no existing file is FAIL by name, not a dropped operand"
else
    echo "selftest FAIL: plant 3st went red for the wrong reason:"
    sed 's/^/      /' "$WORK/3st.err"
    fails=1
fi

# 3stx: the same rule on the axis the suffix cannot express. `-x c <unit>`
# names a translation unit whose SUFFIX says nothing, so round 6's exception
# (keyed on the C-family suffix) let a MISSING one be dropped and the gate
# printed `OK: examined 23`, rc 0, on a recipe emcc would refuse (measured by
# a blind critic, 2026-09-21). Plant 2u is its existing twin: an `-x c` unit
# that IS there must be examined. Both directions now.
awk '{ print } /^[ \t]*"\$\{SOURCES\[@\]\}"[ \t]*\\[ \t]*$/ { print "    -x c web/eigs_ilp32_plant_3stx_missing.inc -x none \\" }' \
    "$BUILD_SH" > "$WORK/3stx.sh"
if ! sandbox_prepare "$WORK/sbx-3stx" "$WORK/3stx.sh" 2>"$WORK/3stx.prep.err"; then
    echo "selftest FAIL: plant 3stx could not be staged:"
    sed 's/^/      /' "$WORK/3stx.prep.err"
    fails=1
elif sandbox_record_inputs "$WORK/sbx-3stx" "$WORK/3stx.tus" 2>"$WORK/3stx.err"; then
    echo "selftest FAIL: plant 3stx (a -x c unit naming no existing file) was accepted — a TU the recipe names and the gate cannot examine"
    fails=1
elif grep -q "as a '-x c' translation unit, and it does not exist" "$WORK/3stx.err"; then
    echo "selftest ok: plant 3stx a -x c token naming no existing file is FAIL by name, not a dropped operand"
else
    echo "selftest FAIL: plant 3stx went red for the wrong reason:"
    sed 's/^/      /' "$WORK/3stx.err"
    fails=1
fi

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

# 2wp: the SAME claim, on the side of the `cd` plant 2w cannot reach. Round 6
# ran the recipe from the GATE's cwd, so a relative write placed BEFORE the
# recipe's own `cd "$(dirname "$0")/.."` resolved against the REAL tree: a
# blind critic landed `web/eigs_critic_precd.txt` and `src/eigs_critic_precd.h`
# in the working tree with the gate printing `OK: examined 23`, rc 0
# (2026-09-21). Plant 2w inserts after the `cd` and passed throughout. The
# anchor is the `cd` line itself, so this plant cannot silently migrate to the
# other side of it.
awk '/^cd "\$\(dirname "\$0"\)\/\.\."$/ { print "printf '"'"'/* planted */\\n'"'"' > src/eigs_ilp32_plant_2wp.h"; seen = 1 }
     { print }
     END { if (!seen) exit 3 }' "$BUILD_SH" > "$WORK/2wp.sh"
if [ $? -ne 0 ]; then
    echo "selftest FAIL: plant 2wp was a no-op — the recipe's own cd line was not found, so nothing was inserted before it"
    fails=1
elif cmp -s "$BUILD_SH" "$WORK/2wp.sh"; then
    echo "selftest FAIL: plant 2wp was a no-op — the scratch recipe is identical to the live one"
    fails=1
elif ! sandbox_prepare "$WORK/sbx-2wp" "$WORK/2wp.sh" 2>"$WORK/2wp.prep.err"; then
    echo "selftest FAIL: plant 2wp could not be staged:"
    sed 's/^/      /' "$WORK/2wp.prep.err"
    fails=1
elif ! sandbox_record_inputs "$WORK/sbx-2wp" "$WORK/2wp.tus" 2>"$WORK/2wp.err"; then
    echo "selftest FAIL: plant 2wp — the recipe that writes into src/ before its own cd did not complete:"
    sed 's/^/      /' "$WORK/2wp.err"
    fails=1
elif ! [ -f "$WORK/sbx-2wp/src/eigs_ilp32_plant_2wp.h" ]; then
    echo "selftest FAIL: plant 2wp was a no-op — the pre-cd line never wrote the file, so the sandbox proved nothing"
    fails=1
elif [ -e "$REPO/src/eigs_ilp32_plant_2wp.h" ]; then
    echo "selftest FAIL: plant 2wp — a recipe line writing src/eigs_ilp32_plant_2wp.h BEFORE the recipe's own cd LANDED IN THE WORKING TREE; the sandbox holds only after that cd"
    rm -f "$REPO/src/eigs_ilp32_plant_2wp.h"
    fails=1
else
    echo "selftest ok: plant 2wp a recipe writing src/ BEFORE its own cd lands in the sandbox and NOT in the working tree"
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

# ---- #1232 plants: the recorded call's FLAGS reach both the macro-world
# derivation and the TU compile, not only the classifier (8o, 8oc, 8d) ------
# 8o is Astra's measured gap: the live recipe compiles at -O2, which defines
# __OPTIMIZE__ in the REAL target's macro world. A gate that derived both
# worlds and compiled every TU with NEITHER the target's optimisation level
# nor any recorded -D passed a planted #error a real wasm clang at -O2 takes
# RED (src/fsutil.c, measured by a blind critic through the real [99i3]
# section — 46/46 self-test cases green — 2026-09-21, filed #1232).
printf '%s\n' '#if defined(__wasm__) && defined(__OPTIMIZE__)' \
              '#error EIGS_ILP32_PLANT_8O' '#endif' \
              'int eigs_ilp32_plant_8o(void);' > "$WORK/plant8o.c"
expect_tu_red plant8o "plant 8o an arm only taken under the recipe's OWN -O2, reachable only because the recorded call's flags reach the compile" \
    "$WORK/plant8o.c" "EIGS_ILP32_PLANT_8O"

# 8oc is the TRANSVERSE control: withholding the call's flags (round 6/7's
# actual behaviour before this fix — recorded, then discarded) makes the SAME
# probe compile clean, which is the false PASS Astra's chunk.sh run
# reproduced through the real section. Without this control, plant 8o could
# be red for an unrelated reason and prove nothing about the flags.
CALL_FLAGS_ALL_SAVED=(${CALL_FLAGS_ALL[@]+"${CALL_FLAGS_ALL[@]}"})
CALL_FLAGS_ALL=()
if compile_tu "$WORK/plant8o.c" "" "$STUB" 2>"$WORK/plant8oc.err"; then
    echo "selftest ok: control 8oc withholding the recorded call's flags (round 6/7's behaviour) makes the SAME probe compile clean — the flags are what closes plant 8o, not the macro-parity derivation alone"
else
    echo "selftest FAIL: control 8oc — the probe is red even with the call's flags withheld, so plant 8o does not test what it claims:"
    sed 's/^/      /' "$WORK/plant8oc.err"
    fails=1
fi
CALL_FLAGS_ALL=(${CALL_FLAGS_ALL_SAVED[@]+"${CALL_FLAGS_ALL_SAVED[@]}"})

# 8d: the per-call half (Astra's secondary finding, "5-per-call-defines") —
# a fault visible only under the -D an EARLIER call carries, on the SAME
# multi-call shape as plant 2c (a TU compiled by an earlier invocation than
# the link line), so a flat CALL_FLAGS_ALL union that could not tell calls
# apart would still pass this: the fault is conditional on a define ONLY the
# planted call passes, and argv_plant's own presence check runs compile_tu on
# the recorded path, so it goes through call_flags_for_tu exactly as the live
# examine_tus pass does.
awk '/^emcc / { print "emcc -Werror=switch -Werror=comment -Werror=misleading-indentation -DEIGS_ILP32_PLANT_8D_CALL -c web/eigs_ilp32_plant_8d.c -o web/dist/eigs_ilp32_plant_8d.o" }
     { print }
     /^[ \t]*"\$\{SOURCES\[@\]\}"[ \t]*\\[ \t]*$/ { print "    web/dist/eigs_ilp32_plant_8d.o \\" }' \
    "$BUILD_SH" > "$WORK/8d.sh"
argv_plant 8d "plant 8d a fault visible only under the EARLIER call's own -D reaches the compile — per-call flags, not a flat merge" \
    1 "web/eigs_ilp32_plant_8d.c" "" "$(printf '%s\n' '#ifdef EIGS_ILP32_PLANT_8D_CALL' '#error EIGS_ILP32_PLANT_8D' '#endif' 'int eigs_ilp32_plant_8d(void);')" ""

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

# ---- the availability arms (5s, 5sc, 5b1, 5b2, 5b3) ----------------------
# ONE of these may skip, and it is the one the runner counts. Round 5 skipped
# on ANY probe failure and a blind critic reached that branch four ways on
# this Linux box, each `SKIP:` + exit 0 + `TOTAL=0`. Each arm below runs the
# REAL probe and the REAL verdict function, and asserts which of the two
# answers it gets — by name.
#
# $1 key, $2 label, $3 stub dir, $4 system include dir, $5 `skip` or `fail`,
# $6 a literal the verdict line must contain.
avail_arm() {
    local key="$1" label="$2" stubdir="$3" sysdir="$4" want="$5" needle="$6"
    local out="$WORK/$key.out" rc
    if ilp32_capability_probe "$stubdir" "$sysdir" > "$out" 2>&1; then
        if [ "$want" = "available" ]; then
            echo "selftest ok: $label"
            return
        fi
        echo "selftest FAIL: $label — the probe reported this toolchain AVAILABLE, so the gate would run against headers it cannot use and go red on every TU"
        fails=1
        return
    fi
    if [ "$want" = "available" ]; then
        echo "selftest FAIL: $label — the live availability probe now says unavailable, so the whole run below it was vacuous:"
        sed 's/^/      /' "$out"
        fails=1
        return
    fi
    ilp32_availability_verdict "$stubdir" "$sysdir" "$(cat "$out")" > "$WORK/$key.verdict" 2>&1
    rc=$?
    if [ "$want" = skip ] && [ "$rc" -ne 0 ]; then
        echo "selftest FAIL: $label — the SDK's own refusal was not recognised as a skip; the verdict was:"
        sed 's/^/      /' "$WORK/$key.verdict"
        fails=1
        return
    fi
    if [ "$want" = fail ] && [ "$rc" -eq 0 ]; then
        echo "selftest FAIL: $label — a BROKEN GATE was reported as a skip (exit 0). Only the SDK's refusal may skip; everything else is a fault in the gate:"
        sed 's/^/      /' "$WORK/$key.verdict"
        fails=1
        return
    fi
    if ! grep -qF -- "$needle" "$WORK/$key.verdict"; then
        echo "selftest FAIL: $label — the verdict does not name '$needle'; it says:"
        sed 's/^/      /' "$WORK/$key.verdict"
        fails=1
        return
    fi
    echo "selftest ok: $label"
}

# 5s: the ONE case that may skip — a C library with no 32-bit target for its
# own headers, saying so in the SDK's own words. Round 3's probe compiled a TU
# with no includes, which an arm64 mac accepts at -m32 because it never
# reaches a header, so the probe passed on macos-latest and all 23 real TUs
# then failed on `sys/cdefs.h: #error Unsupported architecture`. This plant
# gives the probe a stub whose <stdlib.h> answers exactly that.
mkdir -p "$WORK/skipstub/gnu"
: > "$WORK/skipstub/gnu/stubs-32.h"
: > "$WORK/skipstub/emscripten.h"
printf '%s\n' '#error Unsupported architecture' > "$WORK/skipstub/stdlib.h"
avail_arm 5s "plant 5s a C library that refuses the architecture in the SDK's own words is a SKIP by name" \
    "$WORK/skipstub" "$SYS_INCLUDE_DIR" skip "SKIP: this toolchain's C library has no 32-bit target"

# Control 5sc: the LIVE stub must still be reported available, or "unavailable"
# would only mean "this probe always says no".
avail_arm 5sc "control 5sc this toolchain's own 32-bit C library probe is available" \
    "$STUB" "$SYS_INCLUDE_DIR" available ""

# 5s2: the SECOND wording the SAME SDK emits. Measured on macos-latest at
# 1b5c64d, in ONE probe: `sys/cdefs.h:1068:2: error: Unsupported architecture`
# AND `machine/_types.h:36:2: error: architecture not supported`. Round 6
# matched only the first, so an SDK or header reorder leaving only the second
# would have made macos-latest a RED lane by name. This plant gives the probe a
# stub that emits ONLY the second phrasing — with the first one absent, so the
# alternation is the sole evidence (mechanical-gates §38: every alternation
# branch needs a fixture where that branch is the only thing keeping it green).
mkdir -p "$WORK/skipstub2/gnu"
: > "$WORK/skipstub2/gnu/stubs-32.h"
: > "$WORK/skipstub2/emscripten.h"
printf '%s\n' '#error architecture not supported' > "$WORK/skipstub2/stdlib.h"
avail_arm 5s2 "plant 5s2 the SDK's SECOND measured wording ('architecture not supported') is a SKIP by name" \
    "$WORK/skipstub2" "$SYS_INCLUDE_DIR" skip "SKIP: this toolchain's C library has no 32-bit target"

# Control 5sg: the widening must not admit a NON-SDK break. glibc's own refusal
# of a non-conforming compiler is the nearest real neighbour in wording, and it
# must still be FAIL by name — a probe failure that is the gate's apparatus,
# not a capability absence.
mkdir -p "$WORK/glibcstub/gnu"
: > "$WORK/glibcstub/gnu/stubs-32.h"
: > "$WORK/glibcstub/emscripten.h"
printf '%s\n' '#error "You need a ISO C conforming compiler to use the glibc headers"' \
    > "$WORK/glibcstub/stdlib.h"
avail_arm 5sg "control 5sg glibc's 'You need a ISO C' refusal is still FAIL by name, not a skip" \
    "$WORK/glibcstub" "$SYS_INCLUDE_DIR" fail "is NOT this toolchain refusing the architecture"

# 5b1 / 5b2 / 5b3: the three apparatus breaks a blind critic drove to a green
# SKIP on THIS Linux box (2026-09-21). Each must be FAIL BY NAME now.
#   5b1 no compiler on PATH at all,
#   5b2 the gate's own gnu/stubs-32.h stub missing,
#   5b3 the system include directory pointing nowhere.
# 5b1's PATH carries only the text utilities the verdict itself runs, so the
# absence under test is the compiler's and nothing else's.
mkdir -p "$WORK/noclangbin"
for u in cat grep sed; do
    ln -sf "$(command -v "$u")" "$WORK/noclangbin/$u"
done
( PATH="$WORK/noclangbin"; export PATH; fails=0
  avail_arm 5b1 "plant 5b1 no compiler on PATH is FAIL by name, not a skip" \
      "$STUB" "$SYS_INCLUDE_DIR" fail "the compiler it invokes is not on PATH"
  printf '%s' "$fails" > "$WORK/5b1.fails" )
[ "$(cat "$WORK/5b1.fails" 2>/dev/null)" = 0 ] || fails=1

mkdir -p "$WORK/nostub"
: > "$WORK/nostub/emscripten.h"
avail_arm 5b2 "plant 5b2 the gate's own <gnu/stubs-32.h> stub missing is FAIL by name, not a skip" \
    "$WORK/nostub" "$SYS_INCLUDE_DIR" fail "stub is missing from"

avail_arm 5b3 "plant 5b3 a system include directory that does not exist is FAIL by name, not a skip" \
    "$STUB" "$WORK/no-such-include-dir" fail "does not exist on this box"

# Plant 5r: a C library that refuses the macro world the gate DERIVED. Round 5
# made that the second SKIP arm and a blind critic reached it on Linux by
# breaking the derivation — `SKIP:` + exit 0 + `TOTAL=0`, a wrong derivation
# reading as "nothing to say here". Round 6 makes it a FAIL by name, and its
# control runs in the LIVE path (round 5's 5rc was a --selftest case, and the
# section runs --selftest only in the non-skip branch, so on the very run that
# skipped, the control never executed). The probe is poisoned in exactly the
# shape the macOS SDK has: it refuses UNDER the reconciliation (`__wasm__` is
# a target-only predefine, so the reconciliation defines it) and compiles
# clean WITHOUT it, which is the branch the live control distinguishes.
HEADER_PROBE_SAVED="$HEADER_PROBE"
printf '%s\n' '#if defined(__wasm__)' '#error EIGS_ILP32_PLANT_5R_NO_TARGET_MACRO_WORLD' '#endif' \
              'int eigs_ilp32_plant_5r(void);' > "$WORK/poison_probe.c"
HEADER_PROBE="$WORK/poison_probe.c"
MACRO_PARITY_SKIP_REASON=''
if macro_parity_init "$LIVE_TUS" >/dev/null 2>"$WORK/plant5r.err"; then
    echo "selftest FAIL: plant 5r (a C library that refuses the target's macro world) was accepted — the gate would report parity it never verified"
    fails=1
elif [ -n "$MACRO_PARITY_SKIP_REASON" ]; then
    echo "selftest FAIL: plant 5r — a refusal that is NOT the SDK's own was turned into a SKIP reason, which is round 5's green-on-a-broken-derivation exactly: '$MACRO_PARITY_SKIP_REASON'"
    fails=1
elif grep -q 'REFUSE the wasm32 target' "$WORK/plant5r.err" \
     && grep -q 'EIGS_ILP32_PLANT_5R_NO_TARGET_MACRO_WORLD' "$WORK/plant5r.err"; then
    echo "selftest ok: plant 5r a C library that refuses the derived target macro world for a NON-SDK reason is FAIL by name, with its control decided first"
else
    echo "selftest FAIL: plant 5r went red for the wrong reason:"
    sed 's/^/      /' "$WORK/plant5r.err"
    fails=1
fi

# Plant 5rs: the same stage, the OTHER answer — the macOS shape, which is the
# one this arm exists for. macos-latest's availability probe PASSES and the
# SDK refuses only once the reconciliation has replaced `__i386__`/`__APPLE__`
# (CI, 2026-09-21: `sys/cdefs.h:1068: error: Unsupported architecture`). That
# must be a SKIP reason by name — and the suite counts it — while 5r above
# must not be. Without both, "only the SDK may skip" is a claim with one side.
printf '%s\n' '#if defined(__wasm__)' '#error Unsupported architecture' '#endif' \
              'int eigs_ilp32_plant_5rs(void);' > "$WORK/sdk_probe.c"
HEADER_PROBE="$WORK/sdk_probe.c"
MACRO_PARITY_SKIP_REASON=''
if macro_parity_init "$LIVE_TUS" >/dev/null 2>"$WORK/plant5rs.err"; then
    echo "selftest FAIL: plant 5rs (an SDK that refuses the target's macro world) was accepted — the gate would report parity it never verified"
    fails=1
elif grep -qE "$ILP32_SDK_REFUSAL_RE" <<<"$MACRO_PARITY_SKIP_REASON"; then
    echo "selftest ok: plant 5rs an SDK that refuses the architecture in the target's macro world is a SKIP reason by name (the macos-latest shape)"
else
    echo "selftest FAIL: plant 5rs — the SDK's own refusal was not recognised as the one skippable case (skip reason '$MACRO_PARITY_SKIP_REASON'):"
    sed 's/^/      /' "$WORK/plant5rs.err"
    fails=1
fi
HEADER_PROBE="$HEADER_PROBE_SAVED"
MACRO_PARITY_SKIP_REASON=''

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
