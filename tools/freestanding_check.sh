#!/usr/bin/env bash
# Freestanding symbol gate — turns docs/FREESTANDING.md from a document
# into a CI check.
#
# Compiles the runtime (the minimal SOURCES set minus main.c — the
# freestanding consumer enters via eigs_embed.h, not the POSIX CLI) with
# the freestanding profile define + flags, links it relocatable, and
# asserts every remaining undefined symbol is in
# tools/freestanding_allowlist.txt (the HAL roots + mini-libc/libm the
# EigenOS port must provide). Any symbol outside the list means a new
# host dependency leaked into the profile — fail loudly, name it.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

# Anchored to the Makefile's SOURCES (the single source of truth) minus the
# CLI-only units, the same way tools/amalgamate.sh reads it — a hand-written
# list here is a list nothing ties to the tree, and a new runtime TU silently
# missing from it compiles nothing and reports whatever is left (#744).
SRC=$(make --no-print-directory print-SOURCES \
     | tr ' ' '\n' | sed -n 's#^src/\(.*\)\.c$#\1#p')
CLI_ONLY=$(make --no-print-directory print-CLI_ONLY \
     | tr ' ' '\n' | sed -n 's#^src/\(.*\)\.c$#\1#p')
for u in $CLI_ONLY; do SRC=$(printf '%s\n' $SRC | grep -vx "$u"); done
if [ -z "$SRC" ]; then
    echo "FAIL: derived an EMPTY source list from the Makefile" >&2
    exit 1
fi
for f in $SRC; do
    gcc -O2 -ffreestanding -fno-stack-protector -U_FORTIFY_SOURCE \
        -Werror=implicit-function-declaration -Werror=switch -Werror=comment -Werror=misleading-indentation \
        -DEIGENSCRIPT_FREESTANDING=1 \
        -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_MODEL=0 -DEIGENSCRIPT_EXT_DB=0 \
        -c "src/$f.c" -o "$BUILD/$f.o"
done
ld -r -o "$BUILD/all.o" "$BUILD"/*.o

nm -u "$BUILD/all.o" | awk '{print $2}' | grep -v '^_GLOBAL_OFFSET_TABLE_$' \
    | sort -u > "$BUILD/undefined.txt"
grep -v '^#' tools/freestanding_allowlist.txt | grep -v '^$' | sort -u > "$BUILD/allow.txt"

extra=$(comm -23 "$BUILD/undefined.txt" "$BUILD/allow.txt")
unused=$(comm -13 "$BUILD/undefined.txt" "$BUILD/allow.txt")

n_undef=$(wc -l < "$BUILD/undefined.txt")
echo "stage 1: $n_undef undefined symbols (allowlist $(wc -l < "$BUILD/allow.txt"))"

if [ -n "$unused" ]; then
    echo "note: allowlisted but not currently imported (toolchain-dependent, not an error):"
    echo "$unused" | sed 's/^/  /'
fi
if [ -n "$extra" ]; then
    echo "FAIL: symbols imported outside the freestanding allowlist:"
    echo "$extra" | sed 's/^/  /'
    echo "Either carve the caller out under EIGENSCRIPT_FREESTANDING or add the"
    echo "symbol to tools/freestanding_allowlist.txt WITH its HAL/mini-libc story."
    exit 1
fi
echo "OK stage 1: freestanding import surface is within the ledger allowlist"

# ---- stage 2: link the mini-libc/libm in; the residue must be exactly
# the kernel-owed HAL roots (tools/freestanding_hal_roots.txt) ----
for f in mini_libc mini_libm mini_fmt mini_strtod; do
    gcc -O2 -ffreestanding -fno-builtin -ffp-contract=off -fno-math-errno \
        -fno-stack-protector -U_FORTIFY_SOURCE \
        -Werror=implicit-function-declaration -Werror=switch -Werror=comment -Werror=misleading-indentation \
        -DEIGS_MINI_STANDARD_NAMES=1 \
        -c "src/freestanding/$f.c" -o "$BUILD/$f.o"
done
ld -r -o "$BUILD/stage2.o" "$BUILD/all.o" \
    "$BUILD/mini_libc.o" "$BUILD/mini_libm.o" "$BUILD/mini_fmt.o" "$BUILD/mini_strtod.o"
nm -u "$BUILD/stage2.o" | awk '{print $2}' | grep -v '^_GLOBAL_OFFSET_TABLE_$' \
    | sort -u > "$BUILD/residue.txt"
grep -v '^#' tools/freestanding_hal_roots.txt | grep -v '^$' | sort -u > "$BUILD/roots.txt"

extra2=$(comm -23 "$BUILD/residue.txt" "$BUILD/roots.txt")
missing2=$(comm -13 "$BUILD/residue.txt" "$BUILD/roots.txt")
echo "stage 2: $(wc -l < "$BUILD/residue.txt") symbols after mini-libc (HAL roots $(wc -l < "$BUILD/roots.txt"))"
if [ -n "$extra2" ]; then
    echo "FAIL: mini-libc left non-HAL symbols unresolved:"
    echo "$extra2" | sed 's/^/  /'
    exit 1
fi
if [ -n "$missing2" ]; then
    echo "note: HAL roots not currently imported:"
    echo "$missing2" | sed 's/^/  /'
fi
echo "OK stage 2: residue is exactly the kernel-owed HAL roots"
