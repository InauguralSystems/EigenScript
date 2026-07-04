#!/bin/bash
# PostToolUse[Edit|Write] — inject the doc surfaces coupled to the file
# just edited back into the model's context. Advisory by design (the
# blocking arm is the stop gate's doc-delta check); this makes the
# coupling visible at the moment of the edit instead of at the gate.
f=$(jq -r '.tool_input.file_path // empty')
ctx=""
case "$f" in
  */src/lexer.c|*/src/parser.c|*/src/builtins.c|*/src/vm.c|*/src/compiler.c|*/src/eigenscript.c|*/src/vm.h)
    ctx="Doc coupling: $f is a SEMANTICS surface. House rule: semantics changes update docs/SPEC.md + docs/COMPARISON.md in the SAME PR (their examples run byte-for-byte in CI, suite [89]/[90]) and add a CHANGELOG [Unreleased] entry." ;;
  */lib/*.eigs)
    ctx="Doc coupling: $f is a stdlib module. Every module keeps its docs/STDLIB.md entry, its tests/ file, and a CHANGELOG [Unreleased] line current." ;;
  */src/eigs_embed.h|*/src/eigs_embed.c)
    ctx="Doc coupling: $f is the embed API. docs/EMBEDDING.md documents this surface — update it if the API shape moved." ;;
  */src/freestanding/*)
    ctx="Doc coupling: $f is the freestanding profile. docs/FREESTANDING.md and the allowlist gates document this surface." ;;
esac
[ -n "$ctx" ] && jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
exit 0
