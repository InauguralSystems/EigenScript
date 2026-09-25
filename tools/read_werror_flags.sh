#!/bin/sh
# Source with WERROR_FLAGS_FILE set to the shared flags home.
if [ ! -r "${WERROR_FLAGS_FILE:-}" ] || ! WERROR_FLAGS=$(cat "$WERROR_FLAGS_FILE") || [ -z "$WERROR_FLAGS" ]; then
    echo "werror flags: missing, unreadable or empty ${WERROR_FLAGS_FILE:-<unset>}" >&2
    exit 1
fi
export WERROR_FLAGS
