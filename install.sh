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
# Override for isolated install-layout verification; the normal user prefix
# remains ~/.local. Keep HOME untouched when exercising a temporary install.
INSTALL_PREFIX="${EIGENSCRIPT_INSTALL_PREFIX:-$HOME/.local}"
mkdir -p "$INSTALL_PREFIX/bin"
mkdir -p "$INSTALL_PREFIX/lib/eigenscript"
VERSION=$(cat VERSION)

# Build and install minimal
./build.sh
cp src/eigenscript "$INSTALL_PREFIX/bin/eigenscript"
chmod +x "$INSTALL_PREFIX/bin/eigenscript"

# Build and install the language server alongside it — the toolchain is one
# artifact (the VS Code extension in editors/vscode/ auto-launches `eigenlsp`).
./build.sh lsp
cp src/eigenlsp "$INSTALL_PREFIX/bin/eigenlsp"
chmod +x "$INSTALL_PREFIX/bin/eigenlsp"
echo "Language server installed: $INSTALL_PREFIX/bin/eigenlsp"

# Install stdlib
cp -r lib/*.eigs "$INSTALL_PREFIX/lib/eigenscript/"
echo "Stdlib installed to $INSTALL_PREFIX/lib/eigenscript/"

# Build and install full only when explicitly requested.
if [ "${1:-}" = "full" ]; then
    ./build.sh full
    cp src/eigenscript "$INSTALL_PREFIX/bin/eigenscript-full"
    chmod +x "$INSTALL_PREFIX/bin/eigenscript-full"
    echo ""
    echo "Installed:"
    echo "  $INSTALL_PREFIX/bin/eigenscript       (v$VERSION, minimal, $(du -sh "$INSTALL_PREFIX/bin/eigenscript" | cut -f1))"
    echo "  $INSTALL_PREFIX/bin/eigenscript-full  (v$VERSION, with extensions, $(du -sh "$INSTALL_PREFIX/bin/eigenscript-full" | cut -f1))"
else
    echo ""
    echo "Installed: $INSTALL_PREFIX/bin/eigenscript (v$VERSION, minimal)"
    echo "           $INSTALL_PREFIX/bin/eigenlsp     (v$VERSION, language server)"
    echo "Run './install.sh full' to also install eigenscript-full."
fi

echo ""
echo "Make sure $INSTALL_PREFIX/bin is in your PATH:"
printf '  export PATH="%s/bin:$PATH"\n' "$INSTALL_PREFIX"
