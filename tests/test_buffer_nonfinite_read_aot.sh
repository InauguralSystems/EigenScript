#!/usr/bin/env bash
# #1417 VM/AOT differential.  Ouroboros is a sibling repository rather than
# an EigenScript dependency, so the ordinary standalone checkout skips this
# mirror; consumer/parity CI supplies OUROBOROS_DIR and makes it mandatory.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
EIGS=${EIGS:-$ROOT/src/eigenscript}
OUROBOROS_DIR=${OUROBOROS_DIR:-$ROOT/../ouroboros}
FIXTURE=$ROOT/tests/test_buffer_nonfinite_read.eigs
EXPECTED=$ROOT/tests/test_buffer_nonfinite_read.out

if [ ! -f "$OUROBOROS_DIR/aot/build.sh" ]; then
    echo "SKIP: ouroboros AOT checkout not found at $OUROBOROS_DIR"
    exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs-1417-aot.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

EIGS_STRICT=0 "$EIGS" "$FIXTURE" > "$TMP/vm.out"
EIGS_DIR="$ROOT" EIGS="$EIGS" \
    bash "$OUROBOROS_DIR/aot/build.sh" "$FIXTURE" "$TMP/aot-bin"
EIGS_STRICT=0 "$TMP/aot-bin" > "$TMP/aot.out"

diff -u "$EXPECTED" "$TMP/vm.out"
diff -u "$TMP/vm.out" "$TMP/aot.out"
echo "PASS: #1417 VM and ouroboros AOT output are byte-identical"
