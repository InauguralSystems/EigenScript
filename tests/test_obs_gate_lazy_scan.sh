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
cat > "$TMP/fstr_clean.eigs" <<'EIGS'
x is 1
text is f"{x + 1}"
EIGS
cat > "$TMP/fstr_reader.eigs" <<'EIGS'
text is f"{report of x}"
EIGS
cat > "$TMP/fstr_nested_clean.eigs" <<'EIGS'
x is 1
text is f"{f"{x + 1}"}"
EIGS
cat > "$TMP/fstr_nested_reader.eigs" <<'EIGS'
x is 1
text is f"{f"{report of x}"}"
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

gate_for() {
    module=$1
    cat > "$TMP/fstr_host.eigs" <<EOF2
define optional() as:
    return load_file of "$module"
print of "ok"
EOF2
    EIGS_OBS_GATE_STATS=1 "$EIGS" "$TMP/fstr_host.eigs" 2>&1
}

fstr_control=$(gate_for "$TMP/fstr_clean.eigs")
printf '%s\n' "$fstr_control" | grep -q 'obs-gate: unobserved' || fail "plain f-string interpolation opened the gate"
ok "plain f-string interpolation in a lazy module leaves the gate closed"

fstr_plant=$(gate_for "$TMP/fstr_reader.eigs")
printf '%s\n' "$fstr_plant" | grep -q 'obs-gate: observed' || fail "observer reader in an f-string interpolation did not arm the gate"
ok "observer reader in an f-string interpolation arms the gate"

nested_control=$(gate_for "$TMP/fstr_nested_clean.eigs")
printf '%s\n' "$nested_control" | grep -q 'obs-gate: unobserved' || fail "plain nested f-string opened the gate"
nested_plant=$(gate_for "$TMP/fstr_nested_reader.eigs")
printf '%s\n' "$nested_plant" | grep -q 'obs-gate: observed' || fail "observer reader in a nested f-string did not arm the gate"
ok "nested f-string interpolation is scanned in both directions"
