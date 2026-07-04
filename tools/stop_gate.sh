#!/bin/bash
# Stop-hook gate: Claude Code may not end a turn with UNCOMMITTED source
# changes that don't build and pass the smoke check. Scope is deliberate:
#  - clean tree (or non-source changes only) -> exit 0 immediately, so
#    conversational stops and doc work cost nothing;
#  - dirty src/lib/tests -> incremental build + one self-asserting suite
#    file (~seconds), exit 2 with the failure on stderr so Claude keeps
#    working instead of stopping on red.
# Escape hatch if the gate itself misbehaves: touch /tmp/eigs_stop_gate_off
# (or disable via /hooks).
[ -f /tmp/eigs_stop_gate_off ] && exit 0
cd "$(dirname "$0")/.." || exit 0
git diff --quiet HEAD -- src lib 2>/dev/null && exit 0

LOG=/tmp/eigs_stop_gate.log
if ! make -s >"$LOG" 2>&1; then
    { echo "STOP GATE: build FAILED with uncommitted src changes:"; tail -15 "$LOG"; } >&2
    exit 2
fi
if ! ./src/eigenscript tests/test_hex_literals.eigs >>"$LOG" 2>&1; then
    { echo "STOP GATE: smoke suite FAILED (test_hex_literals):"; tail -10 "$LOG"; } >&2
    exit 2
fi
exit 0
