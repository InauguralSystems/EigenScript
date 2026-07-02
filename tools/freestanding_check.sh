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

SRC="eigenscript lexer parser builtins builtins_tensor hash arena state strbuf ext_store fmt lint chunk compiler vm jit trace eigs_embed"
for f in $SRC; do
    gcc -O2 -ffreestanding -fno-stack-protector -U_FORTIFY_SOURCE \
        -Werror=implicit-function-declaration \
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
echo "freestanding-check: $n_undef undefined symbols (allowlist $(wc -l < "$BUILD/allow.txt"))"

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
echo "OK: freestanding import surface is within the ledger allowlist"
