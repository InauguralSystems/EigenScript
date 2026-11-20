#!/usr/bin/env bash
WERROR_FLAGS_FILE="$(dirname "$0")/werror_flags.txt"
. "$(dirname "$0")/read_werror_flags.sh" || exit 1
# Freestanding symbol gate — turns docs/FREESTANDING.md from a document
# into a CI check.  ISO C makes freestanding behavior independent of both
# optimization and the hosted libc headers, so exercise both axes (#1985).
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT_BUILD=$(mktemp -d)
trap 'rm -rf "$ROOT_BUILD"' EXIT

# A hosted rand/srand stream would sit outside both seed_random and the replay
# tape.  Keep this source-level half of the symbol gate deliberately strict:
# spelling a call in runtime code is forbidden, while the freestanding libc's
# implementation remains available to EigenOS consumers (#1818).
#
# Fail closed: git grep exits 1 for "no match" and >=2 for an error. CI runs
# this in a container as a different user from the one that checked the tree
# out, so git refused the repository ("dubious ownership", rc 128) and the old
# `|| true` turned that refusal into an empty result and an OK (#2308, hq#58
# ES-CIB-1). Trust exactly this checkout, as tools/enrolment_check.sh does, and
# treat as FAIL any other git failure, an empty population, a tracked file
# that is not there to be read, and anything git grep says on its error stream.
# The floor is a non-empty tracked population, not a pinned count. This half
# is a word search with no lexing: a line of a tracked hosted source or header
# (src/ and extensions/, outside src/freestanding) that holds the word `rand`
# or `srand` fails, whether the word stands in code, in a comment or in a
# string. So it sees a call, a macro body, an inline in a header, an alias and
# a function pointer in every file, built or not, and inside every
# EIGENSCRIPT_EXT_* block. It also refuses a member or a local that is named
# rand. It does not see a name the preprocessor puts together (`ra##nd`, or
# the name split over a line end): the object check below sees those in the
# code it compiles (the Makefile's SOURCES with every extension off), and
# nothing sees them in the other files or inside an extension's block. random, rand_r and
# drand48 are not searched for: issue #2309 names rand and srand.
#
# `--rng-only` stops after this check (tests/test_freestanding_rng_2308.sh uses
# it to drive the real check cheaply); `make freestanding-check` and CI pass no
# argument and run the whole gate. The word search covers the whole tracked
# population and runs wherever git does. The object check below compiles the
# Makefile's SOURCES with the extensions off and reads their undefined
# symbols; its compile rows run on the Linux lanes, and its match takes the
# leading underscore that nm prints on macOS.
RNG_PATHSPEC=('src/*.c' 'src/*.h' 'extensions/*.c' 'extensions/*.h' ':(exclude)src/freestanding/*')
RNG_GIT=(git -c safe.directory="$(pwd -P)" -c core.quotePath=false)
RNG_ERR="$ROOT_BUILD/rng_ls_files.err"
rng_rc=0
# stderr kept apart so a git warning is never counted as an examined file.
RNG_FILES=$("${RNG_GIT[@]}" ls-files -- "${RNG_PATHSPEC[@]}" 2>"$RNG_ERR") || rng_rc=$?
if [ "$rng_rc" -ne 0 ] || [ -z "$RNG_FILES" ]; then
    echo "FAIL: hosted RNG check examined no runtime sources (git ls-files rc=$rng_rc):" >&2
    cat "$RNG_ERR" >&2
    exit 1
fi
RNG_EXAMINED=$(printf '%s\n' "$RNG_FILES" | wc -l | tr -d ' ')
# git grep passes over a tracked file it cannot open with a message and "no
# match", and says nothing of one that is not in the working tree. So every
# tracked file of the population must be there and readable first.
while IFS= read -r rng_file; do
    [ -n "$rng_file" ] || continue
    if [ ! -f "$rng_file" ] || [ ! -r "$rng_file" ]; then
        echo "FAIL: hosted RNG check cannot read the tracked file $rng_file" >&2
        exit 1
    fi
done <<RNG_LIST
$RNG_FILES
RNG_LIST
RNG_GREP_ERR="$ROOT_BUILD/rng_grep.err"
rng_rc=0
RNG_HITS=$("${RNG_GIT[@]}" grep -n -w -E 'rand|srand' -- "${RNG_PATHSPEC[@]}" 2>"$RNG_GREP_ERR") || rng_rc=$?
if [ -s "$RNG_GREP_ERR" ] && [ "$rng_rc" -le 1 ]; then
    echo "FAIL: hosted RNG check: git grep reported a problem while searching the runtime sources:" >&2
    cat "$RNG_GREP_ERR" >&2
    exit 1
fi
if [ "$rng_rc" -eq 0 ]; then
    echo "FAIL: the word rand or srand appears in a hosted runtime source or header (code, comment or string); the runtime draws from the taped random stream:" >&2
    echo "$RNG_HITS" >&2
    exit 1
elif [ "$rng_rc" -ne 1 ]; then
    echo "FAIL: hosted RNG check could not search the runtime sources (git grep rc=$rng_rc):" >&2
    cat "$RNG_GREP_ERR" >&2
    exit 1
fi
echo "OK hosted RNG: the words rand and srand appear in none of the $RNG_EXAMINED tracked hosted C source/header file(s)"

# Anchor the population to the Makefile's source lists, as amalgamate does.
SRC=$(make --no-print-directory print-SOURCES |
      tr ' ' '\n' | sed -n 's#^src/\(.*\)\.c$#\1#p')
HOSTED_SRC=$SRC
CLI_ONLY=$(make --no-print-directory print-CLI_ONLY |
      tr ' ' '\n' | sed -n 's#^src/\(.*\)\.c$#\1#p')
for u in $CLI_ONLY; do SRC=$(printf '%s\n' $SRC | grep -vx "$u"); done
if [ -z "$SRC" ]; then
    echo "FAIL: derived an EMPTY source list from the Makefile" >&2
    exit 1
fi

command -v nm >/dev/null 2>&1 || {
    echo "FAIL: hosted RNG object check requires nm" >&2
    exit 1
}
HOSTED_RNG_BUILD="$ROOT_BUILD/hosted-rng"
mkdir "$HOSTED_RNG_BUILD"
HOSTED_RNG_OBJECTS=0
for f in $HOSTED_SRC; do
    obj="$HOSTED_RNG_BUILD/$f.o"
    if ! gcc -O0 $WERROR_FLAGS -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_DB=0 \
        -DEIGENSCRIPT_EXT_NET=0 -DEIGENSCRIPT_EXT_GFX=0 \
        -c "src/$f.c" -o "$obj"; then
        echo "FAIL: hosted RNG check could not build src/$f.c" >&2
        exit 1
    fi
    HOSTED_RNG_OBJECTS=$((HOSTED_RNG_OBJECTS + 1))
done
if [ "$HOSTED_RNG_OBJECTS" -eq 0 ]; then
    echo "FAIL: hosted RNG check examined 0 hosted objects" >&2
    exit 1
fi
HOSTED_RNG_UNDEFINED="$HOSTED_RNG_BUILD/undefined.txt"
nm -u "$HOSTED_RNG_BUILD"/*.o 2>"$HOSTED_RNG_BUILD/nm.err" \
    | awk '{print $NF}' | sort -u > "$HOSTED_RNG_UNDEFINED" || {
        echo "FAIL: hosted RNG check could not read hosted objects with nm" >&2
        cat "$HOSTED_RNG_BUILD/nm.err" >&2
        exit 1
    }
if grep -E '^_?(rand|srand)$' "$HOSTED_RNG_UNDEFINED" > "$HOSTED_RNG_BUILD/violations.txt"; then
    echo "FAIL: hosted runtime objects import libc rand/srand outside the taped random stream:" >&2
    cat "$HOSTED_RNG_BUILD/violations.txt" >&2
    exit 1
fi
echo "OK hosted RNG objects: no libc rand/srand imports in $HOSTED_RNG_OBJECTS hosted object(s)"
[ "${1:-}" != "--rng-only" ] || exit 0

run_row() {
    local label=$1 cc=$2 opt=$3
    local BUILD="$ROOT_BUILD/$label"
    mkdir "$BUILD"
    echo "freestanding row: $label ($cc $opt)"
    for f in $SRC; do
        "$cc" "$opt" -ffreestanding -fno-stack-protector -U_FORTIFY_SOURCE \
            -Werror=implicit-function-declaration $WERROR_FLAGS \
            -DEIGENSCRIPT_FREESTANDING=1 \
            -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_DB=0 \
            -c "src/$f.c" -o "$BUILD/$f.o"
    done
    "$cc" "$opt" -ffreestanding -fno-builtin -fno-stack-protector -U_FORTIFY_SOURCE \
        -Werror=implicit-function-declaration $WERROR_FLAGS \
        -DEIGENSCRIPT_FREESTANDING=1 \
        -c tools/eigenos_consumer_check.c -o "$BUILD/eigenos_consumer_check.o"
    ld -r -o "$BUILD/all.o" "$BUILD"/*.o

    nm -u "$BUILD/all.o" | awk '{print $2}' | grep -v '^_GLOBAL_OFFSET_TABLE_$' \
        | sort -u > "$BUILD/undefined.txt"
    grep -v '^#' tools/freestanding_allowlist.txt | grep -v '^$' | sort -u > "$BUILD/allow.txt"
    local extra unused
    extra=$(comm -23 "$BUILD/undefined.txt" "$BUILD/allow.txt")
    unused=$(comm -13 "$BUILD/undefined.txt" "$BUILD/allow.txt")
    echo "stage 1 [$label]: $(wc -l < "$BUILD/undefined.txt") undefined symbols (allowlist $(wc -l < "$BUILD/allow.txt"))"
    if [ -n "$unused" ]; then
        echo "note: allowlisted but not currently imported (toolchain-dependent, not an error):"
        echo "$unused" | sed 's/^/  /'
    fi
    if [ -n "$extra" ]; then
        echo "FAIL [$label]: symbols imported outside the freestanding allowlist:"
        echo "$extra" | sed 's/^/  /'
        return 1
    fi
    echo "OK stage 1 [$label]: freestanding import surface is within the ledger allowlist"

    for f in mini_libc mini_libm mini_fmt mini_strtod; do
        "$cc" "$opt" -ffreestanding -fno-builtin -ffp-contract=off -fno-math-errno \
            -fno-stack-protector -U_FORTIFY_SOURCE \
            -Werror=implicit-function-declaration $WERROR_FLAGS \
            -DEIGS_MINI_STANDARD_NAMES=1 \
            -c "src/freestanding/$f.c" -o "$BUILD/$f.o"
    done
    ld -r -o "$BUILD/stage2.o" "$BUILD/all.o" \
        "$BUILD/mini_libc.o" "$BUILD/mini_libm.o" "$BUILD/mini_fmt.o" "$BUILD/mini_strtod.o"
    nm -u "$BUILD/stage2.o" | awk '{print $2}' | grep -v '^_GLOBAL_OFFSET_TABLE_$' \
        | sort -u > "$BUILD/residue.txt"
    grep -v '^#' tools/freestanding_hal_roots.txt | grep -v '^$' | sort -u > "$BUILD/roots.txt"
    local extra2 missing2
    extra2=$(comm -23 "$BUILD/residue.txt" "$BUILD/roots.txt")
    missing2=$(comm -13 "$BUILD/residue.txt" "$BUILD/roots.txt")
    echo "stage 2 [$label]: $(wc -l < "$BUILD/residue.txt") symbols after mini-libc (HAL roots $(wc -l < "$BUILD/roots.txt"))"
    if [ -n "$extra2" ]; then
        echo "FAIL [$label]: mini-libc left non-HAL symbols unresolved:"
        echo "$extra2" | sed 's/^/  /'
        return 1
    fi
    if [ -n "$missing2" ]; then
        echo "note: HAL roots not currently imported:"
        echo "$missing2" | sed 's/^/  /'
    fi
    echo "OK stage 2 [$label]: residue is exactly the kernel-owed HAL roots"
}

# The stock compiler covers optimization-sensitive header behavior; musl-gcc
# supplies a second, conforming header implementation which does not use
# glibc's private ctype accessors or optimization-only extern inlines.
command -v musl-gcc >/dev/null || {
    echo "FAIL: musl-gcc is required (install musl-tools)" >&2
    exit 1
}
run_row gcc-O2 gcc -O2
run_row gcc-Os gcc -Os
run_row gcc-O0 gcc -O0
run_row musl-O2 musl-gcc -O2

run_riscv32_row() {
    local label=$1 cpu=$2
    local BUILD="$ROOT_BUILD/$label"
    local ZIG=(python3 -m ziglang cc -target riscv32-linux-musl)
    [ -z "$cpu" ] || ZIG+=("-mcpu=$cpu")
    mkdir "$BUILD"
    echo "freestanding row: $label (zig cc -target riscv32-linux-musl ${cpu:+-mcpu=$cpu})"
    for f in $SRC; do
        "${ZIG[@]}" -O2 -ffreestanding -fno-stack-protector -U_FORTIFY_SOURCE \
            -Werror=implicit-function-declaration $WERROR_FLAGS \
            -DEIGENSCRIPT_FREESTANDING=1 -DEIGENSCRIPT_EXT_HTTP=0 \
            -DEIGENSCRIPT_EXT_DB=0 \
            -c "src/$f.c" -o "$BUILD/$f.o"
    done
    "${ZIG[@]}" -O2 -ffreestanding -fno-builtin -fno-stack-protector \
        -U_FORTIFY_SOURCE -Werror=implicit-function-declaration $WERROR_FLAGS \
        -DEIGENSCRIPT_FREESTANDING=1 -c tools/eigenos_consumer_check.c \
        -o "$BUILD/eigenos_consumer_check.o"

    "${ZIG[@]}" -nostdlib -r -o "$BUILD/all.o" "$BUILD"/*.o
    nm -u "$BUILD/all.o" | awk '{print $2}' | sort -u > "$BUILD/undefined.txt"
    grep -v '^#' tools/freestanding_allowlist.txt | grep -v '^$' | sort -u > "$BUILD/allow.txt"
    local extra
    extra=$(comm -23 "$BUILD/undefined.txt" "$BUILD/allow.txt")
    [ -z "$extra" ] || { echo "FAIL [$label]: symbols imported outside the freestanding allowlist:"; echo "$extra" | sed 's/^/  /'; return 1; }
    echo "OK stage 1 [$label]: freestanding import surface is within the ledger allowlist"

    for f in mini_libc mini_libm mini_fmt mini_strtod; do
        "${ZIG[@]}" -O2 -ffreestanding -fno-builtin -ffp-contract=off \
            -fno-math-errno -fno-stack-protector -U_FORTIFY_SOURCE \
            -Werror=implicit-function-declaration $WERROR_FLAGS \
            -DEIGS_MINI_STANDARD_NAMES=1 -c "src/freestanding/$f.c" \
            -o "$BUILD/$f.o"
    done
    # Compiler helpers are part of the freestanding link just as they are for
    # any compiler-emitted operation; -rtlib=compiler-rt makes that explicit.
    "${ZIG[@]}" -nostdlib -r -rtlib=compiler-rt -o "$BUILD/stage2.o" \
        "$BUILD/all.o" "$BUILD/mini_libc.o" "$BUILD/mini_libm.o" \
        "$BUILD/mini_fmt.o" "$BUILD/mini_strtod.o"
    nm -u "$BUILD/stage2.o" | awk '{print $2}' | sort -u > "$BUILD/residue.txt"
    grep -v '^#' tools/freestanding_hal_roots.txt | grep -v '^$' | sort -u > "$BUILD/roots.txt"
    extra=$(comm -23 "$BUILD/residue.txt" "$BUILD/roots.txt")
    [ -z "$extra" ] || { echo "FAIL [$label]: compiler runtime + mini-libc left non-HAL symbols unresolved:"; echo "$extra" | sed 's/^/  /'; return 1; }
    echo "OK stage 2 [$label]: residue is exactly the kernel-owed HAL roots"
}

command -v python3 >/dev/null && python3 -m ziglang version >/dev/null 2>&1 || {
    echo "FAIL: ziglang==0.17.0 is required for the riscv32 rows" >&2
    exit 1
}
run_riscv32_row riscv32-rv32ima "generic_rv32+m+a"
run_riscv32_row riscv32-rv32imc "generic_rv32+m+c"
