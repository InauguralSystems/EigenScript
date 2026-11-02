#!/bin/bash
# The suite supplies the exact binary under test. Direct runs use the normal
# build.sh location, matching the repository's test-script convention.
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS=${EIGS:-"$TESTS_DIR/../src/eigenscript"}

"$EIGS" "$TESTS_DIR/test_channel_capacity.eigs" || exit $?

. "$TESTS_DIR/timeout_select.sh"
eigs_timeout_select 20

run_row() {
    if [ -n "$EIGS_TMO" ]; then
        $EIGS_TMO "$EIGS" "$1"
    else
        # The suite's parent timeout remains the fallback on macOS, whose
        # base image has neither timeout nor gtimeout.
        "$EIGS" "$1"
    fi
}

run_row "$TESTS_DIR/channel_rendezvous_stress.eigs" || exit $?
run_row "$TESTS_DIR/channel_rendezvous_try_recv.eigs"
