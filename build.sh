#!/bin/bash
# Build EigenScript — the language runtime.
# No external dependencies required.
set -e

cd "$(dirname "$0")/src"

VERSION=$(cat ../VERSION)

gcc -Wall -Wextra -O2 -o eigenscript eigenscript.c \
    -DEIGENSCRIPT_EXT_HTTP=0 \
    -DEIGENSCRIPT_EXT_MODEL=0 \
    -DEIGENSCRIPT_EXT_DB=0 \
    -DEIGENSCRIPT_EXT_AUTH=0 \
    -DEIGENSCRIPT_VERSION="\"$VERSION\"" \
    -lm -lpthread

echo "EigenScript $VERSION built. Binary: $(du -sh eigenscript | cut -f1)"
