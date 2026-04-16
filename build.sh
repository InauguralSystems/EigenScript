#!/bin/bash
# Build EigenScript — the language runtime.
# No external dependencies required for minimal build.
set -e

cd "$(dirname "$0")/src"

VERSION=$(cat ../VERSION)
SOURCES="eigenscript.c builtins.c arena.c main.c"

if [ "$1" = "full" ]; then
    # Full build: all extensions. Requires libpq-dev.
    gcc -Wall -Wextra -O2 -o eigenscript $SOURCES ext_http.c ext_db.c \
        model_io.c model_infer.c model_train.c \
        -I/usr/include/postgresql \
        -DEIGENSCRIPT_VERSION="\"$VERSION\"" \
        -lm -lpthread -lpq
    echo "EigenScript $VERSION (full) built. Binary: $(du -sh eigenscript | cut -f1)"
else
    # Minimal build: language + stdlib only.
    gcc -Wall -Wextra -O2 -o eigenscript $SOURCES \
        -DEIGENSCRIPT_EXT_HTTP=0 \
        -DEIGENSCRIPT_EXT_MODEL=0 \
        -DEIGENSCRIPT_EXT_DB=0 \
        -DEIGENSCRIPT_VERSION="\"$VERSION\"" \
        -lm -lpthread
    echo "EigenScript $VERSION built. Binary: $(du -sh eigenscript | cut -f1)"
fi
