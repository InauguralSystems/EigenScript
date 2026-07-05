#!/bin/bash
# Install EigenScript to ~/.local/bin
# Default install requires only gcc:
#   eigenscript      - minimal build (language + stdlib)
#
# Optional:
#   ./install.sh full installs eigenscript-full with HTTP/DB/model extensions
#   and requires libpq development headers.
set -e

cd "$(dirname "$0")"
mkdir -p ~/.local/bin
mkdir -p ~/.local/lib/eigenscript
VERSION=$(cat VERSION)

# Build and install minimal
./build.sh
cp src/eigenscript ~/.local/bin/eigenscript
chmod +x ~/.local/bin/eigenscript

# Build and install the language server alongside it — the toolchain is one
# artifact (the VS Code extension in editors/vscode/ auto-launches `eigenlsp`).
./build.sh lsp
cp src/eigenlsp ~/.local/bin/eigenlsp
chmod +x ~/.local/bin/eigenlsp
echo "Language server installed: ~/.local/bin/eigenlsp"

# Install stdlib
cp -r lib/*.eigs ~/.local/lib/eigenscript/
echo "Stdlib installed to ~/.local/lib/eigenscript/"

# Build and install full only when explicitly requested.
if [ "${1:-}" = "full" ]; then
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
    echo "           ~/.local/bin/eigenlsp     (v$VERSION, language server)"
    echo "Run './install.sh full' to also install eigenscript-full."
fi

echo ""
echo "Make sure ~/.local/bin is in your PATH:"
echo '  export PATH="$HOME/.local/bin:$PATH"'
