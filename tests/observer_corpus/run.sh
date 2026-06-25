#!/usr/bin/env bash
# Cross-repo observer validation corpus (issue #262).
#
# Runs real observer-using programs harvested from downstream consumer repos
# (dynamics, iLambdaAi) plus EigenScript's own examples, and diffs each
# program's output against a captured value-path golden. Any diff = an
# observer change altered real consumer behavior — the signal a unit suite
# can't give you. Provenance (repo + commit) is in MANIFEST.tsv.
#
# Usage:
#   ./run.sh [BINARY]                 # validate against golden (default binary: ../../src/eigenscript)
#   EIGS_OBS_SHADOW=1 ./run.sh        # validate the slot model vs the value-path golden
#   ./run.sh --capture [BINARY]       # (re)capture golden from BINARY (value path)
#
# Exit 0 iff every program matches its golden.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${HERE}/../../src/eigenscript"
CAPTURE=0
[ "${1:-}" = "--capture" ] && { CAPTURE=1; shift; }
[ $# -ge 1 ] && BIN="$1"
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"

pass=0; fail=0; failed=()
for p in "$HERE"/programs/*.eigs; do
  n="$(basename "${p%.eigs}")"
  out="$(cd "$HERE/programs" && timeout 60 "$BIN" "$(basename "$p")" 2>&1)"
  if [ "$CAPTURE" = 1 ]; then
    printf '%s\n' "$out" > "$HERE/golden/$n.out"
    echo "  captured $n"
    continue
  fi
  if diff -q <(printf '%s\n' "$out") "$HERE/golden/$n.out" >/dev/null 2>&1; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); failed+=("$n")
  fi
done
[ "$CAPTURE" = 1 ] && { echo "golden recaptured."; exit 0; }
echo "------------------------------------------------------------"
echo "observer corpus: ${pass} match, ${fail} diverge  (binary: $BIN${EIGS_OBS_SHADOW:+, EIGS_OBS_SHADOW=$EIGS_OBS_SHADOW})"
if [ "$fail" -gt 0 ]; then
  printf '  DIVERGED: %s\n' "${failed[@]}"
  echo "  (inspect: diff <(cd programs && BIN prog.eigs) golden/prog.out)"
  exit 1
fi
