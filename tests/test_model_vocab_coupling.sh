#!/usr/bin/env bash
# Model training must not compile a consumer's token IDs into the runtime.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if rg -n 'CLS_ID_|CLS_FIRST_IDENT_ID|EIGS_(CLASS|DEPTH)_LOSS_DUMP|EIGS_DEDENT_LOSS_WEIGHT' \
    "$ROOT"/src/model_*.c; then
    echo "FAIL: model runtime still contains consumer-specific vocabulary diagnostics"
    exit 1
fi

echo "PASS: model runtime contains no consumer-specific vocabulary diagnostics"
