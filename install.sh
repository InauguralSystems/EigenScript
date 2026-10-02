#!/bin/bash
# Install EigenScript to ~/.local/bin
# Default install requires only gcc:
#   eigenscript      - hosted release (language + stdlib + lazy gfx)
#
# Optional:
#   ./install.sh server installs eigenscript-server with HTTP + net + model.
#   ./install.sh server-db also installs eigenscript-server-db (requires libpq).
set -e

cd "$(dirname "$0")"
# Override for isolated install-layout verification; the normal user prefix
# remains ~/.local. Keep HOME untouched when exercising a temporary install.
INSTALL_PREFIX="${EIGENSCRIPT_INSTALL_PREFIX:-$HOME/.local}"
mkdir -p "$INSTALL_PREFIX/bin"
mkdir -p "$INSTALL_PREFIX/lib/eigenscript"
VERSION=$(cat VERSION)

# Build and install the hosted release.
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

# Build and install server profiles only when explicitly requested.
if [ "${1:-}" = "server" ] || [ "${1:-}" = "server-db" ] || [ "${1:-}" = "full" ]; then
    ./build.sh server
    cp src/eigenscript "$INSTALL_PREFIX/bin/eigenscript-server"
    chmod +x "$INSTALL_PREFIX/bin/eigenscript-server"
    if [ "${1:-}" = "server-db" ] || [ "${1:-}" = "full" ]; then
        ./build.sh server-db
        cp src/eigenscript "$INSTALL_PREFIX/bin/eigenscript-server-db"
        chmod +x "$INSTALL_PREFIX/bin/eigenscript-server-db"
        # Compatibility executable; new consumers use eigenscript-server-db.
        cp src/eigenscript "$INSTALL_PREFIX/bin/eigenscript-full"
        chmod +x "$INSTALL_PREFIX/bin/eigenscript-full"
    fi
    echo ""
    echo "Installed:"
    echo "  $INSTALL_PREFIX/bin/eigenscript         (v$VERSION, release)"
    echo "  $INSTALL_PREFIX/bin/eigenscript-server  (v$VERSION, HTTP + net + model)"
    [ ! -x "$INSTALL_PREFIX/bin/eigenscript-server-db" ] || echo "  $INSTALL_PREFIX/bin/eigenscript-server-db (v$VERSION, HTTP + net + model + db)"
else
    echo ""
    echo "Installed: $INSTALL_PREFIX/bin/eigenscript (v$VERSION, release)"
    echo "           $INSTALL_PREFIX/bin/eigenlsp     (v$VERSION, language server)"
    echo "Run './install.sh server' to also install eigenscript-server."
fi

echo ""
echo "Make sure $INSTALL_PREFIX/bin is in your PATH:"
printf '  export PATH="%s/bin:$PATH"\n' "$INSTALL_PREFIX"
