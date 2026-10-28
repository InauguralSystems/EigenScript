#!/usr/bin/env bash
set -eu
EIGS=${EIGS:-${EIGENSCRIPT:-$(cd "$(dirname "$0")/.." && pwd)/src/eigenscript}}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
ok() { echo "PASS: $*"; }

cat > "$TMP/clean.eigs" <<'EIGS'
helper_value is 1
EIGS
cat > "$TMP/planted.eigs" <<'EIGS'
# This module is never executed. Its token-level observer read must still arm
# the parent before the parent's first assignment.
print of (report of x)
EIGS
cat > "$TMP/control.eigs" <<EOF2
x is 1.0
define optional() as:
    return load_file of "$TMP/clean.eigs"
print of "ok"
EOF2
cat > "$TMP/plant.eigs" <<EOF2
x is 1.0
define optional() as:
    return load_file of "$TMP/planted.eigs"
print of "ok"
EOF2

control=$(EIGS_OBS_GATE_STATS=1 "$EIGS" "$TMP/control.eigs" 2>&1)
printf '%s\n' "$control" | grep -q 'obs-gate: unobserved' || fail "clean control did not close the gate"
printf '%s\n' "$control" | grep -q '^ok$' || fail "clean control did not execute"
ok "clean lazy module leaves the observer gate closed"

plant=$(EIGS_OBS_GATE_STATS=1 "$EIGS" "$TMP/plant.eigs" 2>&1)
printf '%s\n' "$plant" | grep -q 'obs-gate: observed' || fail "observer-reading lazy module did not arm the gate"
printf '%s\n' "$plant" | grep -q '^ok$' || fail "planted parent did not execute"
ok "observer read in an uncalled function's literal module arms the gate"
