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

# Doc-delta check: a change to the semantics surface or stdlib with NO
# movement in CHANGELOG/docs is either missing its documentation or is
# doc-neutral — and doc-neutrality must be DECLARED, not defaulted
# (touch /tmp/eigs_doc_neutral; consumed per stop, like the abort flag).
SEMSURF="src/lexer.c src/parser.c src/builtins.c src/vm.c src/compiler.c src/vm.h src/eigs_embed.h src/eigs_embed.c lib"
if ! git diff --quiet HEAD -- $SEMSURF 2>/dev/null; then
    if git diff --quiet HEAD -- CHANGELOG.md docs 2>/dev/null; then
        if [ -f /tmp/eigs_doc_neutral ]; then
            rm -f /tmp/eigs_doc_neutral
        else
            { echo "STOP GATE: semantics-surface/lib changed with NO CHANGELOG/docs delta."
              echo "Update CHANGELOG [Unreleased] (+ SPEC/COMPARISON if semantics moved,"
              echo "STDLIB.md for lib modules), or declare the change doc-neutral:"
              echo "  touch /tmp/eigs_doc_neutral    (consumed by this stop)"; } >&2
            exit 2
        fi
    fi
fi
exit 0
