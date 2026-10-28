#!/bin/bash
# The suite supplies the exact binary under test. Direct runs use the normal
# build.sh location, matching the repository's test-script convention.
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS=${EIGS:-"$TESTS_DIR/../src/eigenscript"}
"$EIGS" "$TESTS_DIR/test_channel_capacity.eigs"
