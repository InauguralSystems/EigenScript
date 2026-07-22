#!/bin/bash
# Build EigenScript — the language runtime.
# No external dependencies required for minimal build.
set -e

cd "$(dirname "$0")/src"

VERSION=$(cat ../VERSION)
# Compiler is overridable (e.g. CC=clang ./build.sh) so CI can exercise
# more than one toolchain; defaults to gcc.
CC="${CC:-gcc}"
# Anti-drift: the source list is read from the Makefile's SOURCES (the
# single source of truth), like tools/amalgamate.sh already does. build.sh
# used to carry its own copy and it silently fell behind every time a new
# translation unit landed — the CI legs that build through this script
# (install.sh, bench, the OS matrix) then failed at link while `make` was
# green (step.c was the latest instance of the class).
SOURCES=$(grep '^SOURCES :=' ../Makefile | sed 's/^SOURCES :=//; s|\$(SRC_DIR)/||g')
CLI_ONLY=$(grep '^CLI_ONLY :=' ../Makefile | sed 's/^CLI_ONLY :=//; s|\$(SRC_DIR)/||g')
if [ -z "$SOURCES" ]; then
    echo "build.sh: cannot read SOURCES from ../Makefile" >&2
    exit 1
fi

# macOS Intel JIT: enabled via the Mach-O TLV-aware prologue (the JIT
# now calls eigs_jit_load_eigs_current instead of inlining %fs:
# tpoff, which is Linux-ELF-only). The dict-field inline cache stays
# off on Darwin — see eigs_jit_get_layout in vm.c — so LOCAL_DOT_GET
# falls through to the slow-path helper. EIGENSCRIPT_JIT_FORCE_OFF
# stays in jit.c as a kill switch for bisection (`./build.sh
# JIT_FLAGS=-DEIGENSCRIPT_JIT_FORCE_OFF=1`).
JIT_FLAGS=""

if [ "$1" = "lsp" ]; then
    # Language server (src/eigenlsp) — the editor-intelligence half of the
    # toolchain. Links eigenlsp.c against the runtime (SOURCES minus the
    # CLI-only units, read from the Makefile's CLI_ONLY so the drop list
    # can't drift either), minimal extensions, gcc-only like the rest of
    # build.sh. The stdlib index header it includes (#590) is generated
    # from lib/ first — same rule as the Makefile lsp target.
    bash ../tools/gen_lsp_stdlib_index.sh
    LSP_SOURCES=" $SOURCES "
    for u in $CLI_ONLY; do LSP_SOURCES="${LSP_SOURCES/ $u / }"; done
    LSP_SOURCES="$LSP_SOURCES eigenlsp.c"
    $CC -Wall -Wextra -Werror=implicit-function-declaration -O2 -fstack-protector-strong -o eigenlsp $LSP_SOURCES \
        -DEIGENSCRIPT_EXT_HTTP=0 \
        -DEIGENSCRIPT_EXT_MODEL=0 \
        -DEIGENSCRIPT_EXT_DB=0 \
        -DEIGENSCRIPT_VERSION="\"$VERSION\"" \
        $JIT_FLAGS \
        -lm -lpthread
    echo "EigenScript LSP $VERSION built. Binary: $(du -sh eigenlsp | cut -f1)"
elif [ "$1" = "full" ]; then
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
