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
HOSTED_RNG_CALLS=$(git grep -n -E '\b(rand|srand)[[:space:]]*\(' -- \
    'src/*.c' 'extensions/*.c' ':(exclude)src/freestanding/*' || true)
if [ -n "$HOSTED_RNG_CALLS" ]; then
    echo "FAIL: hosted runtime calls libc rand/srand outside the taped random stream:" >&2
    echo "$HOSTED_RNG_CALLS" >&2
    exit 1
fi
echo "OK hosted RNG: no libc rand/srand calls outside src/freestanding"

# Anchor the population to the Makefile's source lists, as amalgamate does.
SRC=$(make --no-print-directory print-SOURCES |
      tr ' ' '\n' | sed -n 's#^src/\(.*\)\.c$#\1#p')
CLI_ONLY=$(make --no-print-directory print-CLI_ONLY |
      tr ' ' '\n' | sed -n 's#^src/\(.*\)\.c$#\1#p')
for u in $CLI_ONLY; do SRC=$(printf '%s\n' $SRC | grep -vx "$u"); done
if [ -z "$SRC" ]; then
    echo "FAIL: derived an EMPTY source list from the Makefile" >&2
    exit 1
fi

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
