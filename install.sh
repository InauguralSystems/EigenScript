#!/bin/bash
# Install EigenScript to ~/.local/bin
# Installs two binaries:
#   eigenscript      — minimal build (language + stdlib, 104K)
#   eigenscript-full — full build (+ HTTP/DB/model extensions, 168K)
set -e

cd "$(dirname "$0")"
mkdir -p ~/.local/bin
mkdir -p ~/.local/lib/eigenscript
VERSION=$(cat VERSION)

# Build and install minimal
./build.sh
cp src/eigenscript ~/.local/bin/eigenscript
chmod +x ~/.local/bin/eigenscript

# Install stdlib
cp -r lib/*.eigs ~/.local/lib/eigenscript/
echo "Stdlib installed to ~/.local/lib/eigenscript/"

# Build and install full (if requested or if HTTP/DB/model extensions needed)
if [ "$1" != "minimal-only" ]; then
    ./build.sh full
    cp src/eigenscript ~/.local/bin/eigenscript-full
    chmod +x ~/.local/bin/eigenscript-full
    echo ""
    echo "Installed:"
    echo "  ~/.local/bin/eigenscript       (v$VERSION, minimal, $(du -sh ~/.local/bin/eigenscript | cut -f1))"
    echo "  ~/.local/bin/eigenscript-full  (v$VERSION, with extensions, $(du -sh ~/.local/bin/eigenscript-full | cut -f1))"
else
    echo ""
    echo "Installed: ~/.local/bin/eigenscript (v$VERSION, minimal)"
fi

echo ""
echo "Make sure ~/.local/bin is in your PATH:"
echo '  export PATH="$HOME/.local/bin:$PATH"'
