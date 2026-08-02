#!/usr/bin/env bash
# Embedded-stack soak gate: build the freestanding-profile runtime hosted
# (as freestanding_smoke.sh does) with the REPL-soak harness, then run it
# twice — once with the stack rlimit clamped to 64 KiB, once roomier.
#
# Hosted 8 MiB stacks hide per-AST-level C stack cost completely; this gate
# is what catches a regression like the by-value Compiler in
# compile_node_inner (~12.7 KiB of stack PER AST LEVEL — a 5-deep AST
# overflowed the 64 KiB boot stack EigenOS used at the time and silently
# trampled .bss, the mn-repl "#UD heisenbug"). Under the rlimit, an overflow
# is an instant SIGSEGV instead of a layout-dependent delayed fault.
#
# Run 1 — 64 KiB, the REPL soak. That 64 KiB is a deliberately tight
# PER-LEVEL REGRESSION BUDGET, not a measured EigenOS stack size (#758):
# per that issue EigenOS raised its boot stack as part of the #361 fix, and
# this number was left where it was on purpose. A budget below the real
# target is the right design for the job this gate does — detect a jump in
# stack cost per AST level, the way it caught #361 — but it is NOT a
# worst-case bound, and the depth guards are not sized against it (that
# policy: docs/FREESTANDING.md). Measured on this harness: the soak
# passes 20/20 down to a 32 KiB rlimit, is flaky at 28 and dead at 20, so
# roughly half the 64 KiB budget goes to startup + parse + VM before any
# recursive descent, and the rest survives only because a REPL soak runs
# shallow programs.
#
# Run 2 — 256 KiB, the depth-guard probe (#758). Deeply nested source, at a
# stack where the guard is genuinely the binding constraint, asserting the
# guard's clean diagnostic instead of a SIGSEGV. At 64 KiB the same input is
# SIGSEGV 20/20 — the guard cannot be reached there at all, which is why
# "the guard fires cleanly" was assumed and never tested. 256 KiB is chosen
# with margin: measured on this harness the guard trips cleanly 20/20 from
# 144 KiB, 18/20 at 128 KiB, and 0/20 at 112 KiB.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

gcc -Werror=implicit-function-declaration -O2 \
    -DEIGENSCRIPT_FREESTANDING=1 \
    -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_MODEL=0 -DEIGENSCRIPT_EXT_DB=0 \
    -o "$BUILD/embed_stack_soak" \
    src/eigenscript.c src/lexer.c src/parser.c src/builtins.c \
    src/builtins_host.c \
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

set +e
gout=$(bash -c "ulimit -s 256; '$BUILD/embed_stack_soak' depth-guard" 2>&1); grc=$?
set -e

# All three conditions matter: rc 0 rules out the SIGSEGV (139) this is here to
# distinguish from; the diagnostic proves it was the depth guard that rejected
# the source and not some unrelated parse failure; the marker proves the
# runtime was still usable afterwards.
if [ "$grc" = 0 ] \
   && printf '%s' "$gout" | grep -q "nesting too deep" \
   && printf '%s' "$gout" | grep -q "embed_stack_soak: depth-guard OK"; then
    echo "  PASS: parse-depth guard rejects cleanly in a 256 KiB stack"
else
    echo "  FAIL: depth-guard probe under 256 KiB stack (rc=$grc)"
    # Drop the cascade of follow-on "expected ')'" lines the rejected source
    # produces, so the tail shows the diagnostic that matters.
    printf '%s\n' "$gout" | grep -v "expected ')'" | tail -5
    exit 1
fi
