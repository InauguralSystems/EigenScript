#!/usr/bin/env bash
# Build the EigenScript WASM playground module.
#
# Requires emcc (emscripten). Install:
#   git clone --depth 1 https://github.com/emscripten-core/emsdk.git
#   cd emsdk && ./emsdk install latest && ./emsdk activate latest
#   source ./emsdk_env.sh
#
# Produces web/dist/eigs.{js,wasm} — load eigs.js from a static page; it
# wires up a global Module factory whose .ccall('eigs_run_source', ...)
# runs a script in-process. The companion index.html / app.js / style.css
# in this directory are the playground UI; copy or symlink them into
# web/dist alongside the build outputs to serve a complete site.
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p web/dist

# Core sources — same set as the Makefile's `build` target minus main.c
# (replaced by web/eigs_wasm.c) and minus the optional ext_* / model_*
# units, which depend on HTTP/sockets/threads not available in WASM.
SOURCES=(
    src/eigenscript.c src/lexer.c src/parser.c
    src/builtins.c src/builtins_tensor.c
    src/hash.c src/arena.c src/state.c src/strbuf.c
    src/ext_store.c src/fmt.c src/lint.c
    src/chunk.c src/compiler.c src/vm.c
    src/jit.c src/trace.c
    web/eigs_wasm.c
)

VERSION=$(cat VERSION)

# Exported names — keep this list aligned with EMSCRIPTEN_KEEPALIVE
# functions in web/eigs_wasm.c. _malloc/_free are needed for ccall with
# string args; UTF8ToString is needed to read C strings back.
EXPORTED_FUNCTIONS='["_eigs_run_source","_eigs_version","_malloc","_free"]'
EXPORTED_RUNTIME='["ccall","cwrap","UTF8ToString","stringToUTF8","lengthBytesUTF8"]'

emcc -O2 \
    -DEIGENSCRIPT_EXT_HTTP=0 \
    -DEIGENSCRIPT_EXT_MODEL=0 \
    -DEIGENSCRIPT_EXT_DB=0 \
    -DEIGENSCRIPT_VERSION="\"${VERSION}\"" \
    -sMODULARIZE=1 \
    -sEXPORT_NAME="EigsModule" \
    -sENVIRONMENT=web,node \
    -sALLOW_MEMORY_GROWTH=1 \
    -sINITIAL_MEMORY=33554432 \
    -sSTACK_SIZE=4194304 \
    -sEXPORTED_FUNCTIONS="${EXPORTED_FUNCTIONS}" \
    -sEXPORTED_RUNTIME_METHODS="${EXPORTED_RUNTIME}" \
    -sNO_FILESYSTEM=1 \
    -sASSERTIONS=1 \
    -sERROR_ON_UNDEFINED_SYMBOLS=0 \
    --no-entry \
    "${SOURCES[@]}" \
    -lm \
    -o web/dist/eigs.js

# Copy the UI files to dist so the directory is self-contained.
cp web/index.html web/dist/index.html
cp web/app.js web/dist/app.js
cp web/style.css web/dist/style.css

echo "Built web/dist/ — serve with: python3 -m http.server -d web/dist"
ls -lh web/dist/
