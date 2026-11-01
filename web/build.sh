#!/usr/bin/env bash
WERROR_FLAGS_FILE="$(dirname "$0")/../tools/werror_flags.txt"
. "$(dirname "$0")/../tools/read_werror_flags.sh" || exit 1
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

# Core sources: the Makefile's EMBED_SOURCES (SOURCES minus CLI_ONLY, the
# runtime without main.c and the CLI-only units), plus web/eigs_wasm.c in
# place of main.c. The optional ext_* / model_* units are not in SOURCES.
# Derived, never copied (#2301): a hand-written list here drifted and lost
# src/eigs_embed.c, so eigs_source_lookup was undefined and every `import`
# aborted the deployed playground; tools/embed_stack_soak.sh and
# tools/freestanding_check.sh anchor to the Makefile for the same reason.
mapfile -t SOURCES < <(make --no-print-directory print-EMBED_SOURCES | tr ' ' '\n' | grep '\.c$')
case " ${SOURCES[*]} " in
    *" src/vm.c "*) ;;
    *) echo "FAIL: could not derive the runtime source list from the Makefile (print-EMBED_SOURCES)" >&2; exit 1 ;;
esac
SOURCES+=(web/eigs_wasm.c)

VERSION=$(cat VERSION)

# Exported names — keep this list aligned with EMSCRIPTEN_KEEPALIVE
# functions in web/eigs_wasm.c. _malloc/_free are needed for ccall with
# string args; UTF8ToString is needed to read C strings back.
EXPORTED_FUNCTIONS='["_eigs_run_source","_eigs_version","_malloc","_free"]'
EXPORTED_RUNTIME='["ccall","cwrap","UTF8ToString","stringToUTF8","lengthBytesUTF8"]'

# No -sNO_FILESYSTEM: the runtime writes output through C stdio streams, and
# with the filesystem compiled out every program aborted ("it should not be
# possible to operate on streams when !SYSCALLS_REQUIRE_FILESYSTEM"); the
# deployed v0.48.0 playground could not run print of "hello" (hq#58
# ES-OWF-1). tools/playground_smoke.cjs now runs real programs in CI.
#
# -sERROR_ON_UNDEFINED_SYMBOLS=1: an undefined C symbol fails the link. With
# =0, emcc linked anyway and planted abort("missing function: <name>"), so the
# build was green while any program that reached the symbol killed the module
# (#2301: eigs_source_lookup, reached by every `import`).
emcc $WERROR_FLAGS -O2 \
    -DEIGENSCRIPT_EXT_HTTP=0 \
    \
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
    -sASSERTIONS=1 \
    -sERROR_ON_UNDEFINED_SYMBOLS=1 \
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
