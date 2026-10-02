#!/usr/bin/env bash
# Model training must not compile a consumer's token IDs into the runtime.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

grep_rc=0
grep -En 'CLS_ID_|CLS_FIRST_IDENT_ID|EIGS_(CLASS|DEPTH)_LOSS_DUMP|EIGS_DEDENT_LOSS_WEIGHT' \
    "$ROOT"/src/model_*.c || grep_rc=$?

if [ "$grep_rc" -eq 0 ]; then
    echo "FAIL: model runtime still contains consumer-specific vocabulary diagnostics"
    exit 1
fi

if [ "$grep_rc" -ne 1 ]; then
    echo "FAIL: model runtime vocabulary scan failed (grep rc=$grep_rc)"
    exit 1
fi

echo "PASS: model runtime contains no consumer-specific vocabulary diagnostics"
