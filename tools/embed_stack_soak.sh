#!/usr/bin/env bash
# Embedded-stack soak gate: build the freestanding-profile runtime hosted
# (as freestanding_smoke.sh does) with the REPL-soak harness, then run it
# with the stack rlimit clamped to 64 KiB — the EigenOS boot-stack size.
#
# Hosted 8 MiB stacks hide per-AST-level C stack cost completely; this gate
# is what catches a regression like the by-value Compiler in
# compile_node_inner (~12.7 KiB of stack PER AST LEVEL — a 5-deep AST
# overflowed EigenOS's 64 KiB boot stack and silently trampled .bss, the
# mn-repl "#UD heisenbug"). Under the rlimit, an overflow is an instant
# SIGSEGV instead of a layout-dependent delayed fault.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

gcc -Werror=implicit-function-declaration -O2 \
    -DEIGENSCRIPT_FREESTANDING=1 \
    -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_MODEL=0 -DEIGENSCRIPT_EXT_DB=0 \
    -o "$BUILD/embed_stack_soak" \
    src/eigenscript.c src/lexer.c src/parser.c src/builtins.c \
    src/builtins_tensor.c src/hash.c src/arena.c src/state.c src/strbuf.c \
    src/ext_store.c src/fmt.c src/lint.c src/chunk.c src/compiler.c \
    src/vm.c src/jit.c src/trace.c src/eigs_embed.c \
    tools/embed_stack_soak_main.c \
    -lm -lpthread

set +e
out=$(bash -c "ulimit -s 64; '$BUILD/embed_stack_soak'" 2>&1); rc=$?
set -e

if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q "embed_stack_soak: OK"; then
    echo "  PASS: REPL soak completes in a 64 KiB stack ($out)"
else
    echo "  FAIL: soak under 64 KiB stack (rc=$rc)"
    printf '%s\n' "$out" | tail -5
    exit 1
fi
