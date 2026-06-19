#!/bin/bash
# Build EigenScript — the language runtime.
# No external dependencies required for minimal build.
set -e

cd "$(dirname "$0")/src"

VERSION=$(cat ../VERSION)
# Compiler is overridable (e.g. CC=clang ./build.sh) so CI can exercise
# more than one toolchain; defaults to gcc.
CC="${CC:-gcc}"
SOURCES="eigenscript.c lexer.c parser.c builtins.c builtins_tensor.c hash.c arena.c state.c strbuf.c ext_store.c fmt.c lint.c chunk.c compiler.c vm.c jit.c trace.c main.c"

# macOS Intel JIT: enabled via the Mach-O TLV-aware prologue (the JIT
# now calls eigs_jit_load_eigs_current instead of inlining %fs:
# tpoff, which is Linux-ELF-only). The dict-field inline cache stays
# off on Darwin — see eigs_jit_get_layout in vm.c — so LOCAL_DOT_GET
# falls through to the slow-path helper. EIGENSCRIPT_JIT_FORCE_OFF
# stays in jit.c as a kill switch for bisection (`./build.sh
# JIT_FLAGS=-DEIGENSCRIPT_JIT_FORCE_OFF=1`).
JIT_FLAGS=""

if [ "$1" = "full" ]; then
    # Full build: all extensions. Requires libpq-dev.
    $CC -Wall -Wextra -Werror=implicit-function-declaration -O2 -fstack-protector-strong -o eigenscript $SOURCES ext_http.c ext_db.c \
        model_io.c model_infer.c model_train.c \
        -I/usr/include/postgresql \
        -DEIGENSCRIPT_EXT_HTTP=1 \
        -DEIGENSCRIPT_EXT_MODEL=1 \
        -DEIGENSCRIPT_EXT_DB=1 \
        -DEIGENSCRIPT_VERSION="\"$VERSION\"" \
        $JIT_FLAGS \
        -lm -lpthread -lpq
    echo "EigenScript $VERSION (full) built. Binary: $(du -sh eigenscript | cut -f1)"
else
    # Minimal build: language + stdlib only.
    $CC -Wall -Wextra -Werror=implicit-function-declaration -O2 -fstack-protector-strong -o eigenscript $SOURCES \
        -DEIGENSCRIPT_EXT_HTTP=0 \
        -DEIGENSCRIPT_EXT_MODEL=0 \
        -DEIGENSCRIPT_EXT_DB=0 \
        -DEIGENSCRIPT_VERSION="\"$VERSION\"" \
        $JIT_FLAGS \
        -lm -lpthread
    echo "EigenScript $VERSION built. Binary: $(du -sh eigenscript | cut -f1)"
fi
