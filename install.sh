#!/bin/bash
# Install EigenScript to ~/.local/bin
set -e

cd "$(dirname "$0")"

# Build
./build.sh

# Install
mkdir -p ~/.local/bin
cp src/eigenscript ~/.local/bin/eigenscript
chmod +x ~/.local/bin/eigenscript

VERSION=$(cat VERSION)
echo ""
echo "Installed: ~/.local/bin/eigenscript (v$VERSION)"
echo ""
echo "Make sure ~/.local/bin is in your PATH:"
echo '  export PATH="$HOME/.local/bin:$PATH"'
