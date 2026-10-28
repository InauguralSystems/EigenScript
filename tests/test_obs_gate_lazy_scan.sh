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

cat > "$TMP/soft_keywords.eigs" <<'EIGS'
local at is 1
local prev is 2
EIGS
cat > "$TMP/soft_host.eigs" <<EOF2
define optional() as:
    return load_file of "$TMP/soft_keywords.eigs"
print of "ok"
EOF2
soft=$(EIGS_OBS_GATE_STATS=1 "$EIGS" "$TMP/soft_host.eigs" 2>&1)
printf '%s\n' "$soft" | grep -q 'obs-gate: unobserved' || fail "soft-keyword bindings opened the gate"
printf '%s\n' "$soft" | grep -q '^ok$' || fail "soft-keyword binding control did not execute"
ok "observer soft keywords in binding positions leave the gate closed"

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

# A literal is safe to pre-scan only when it is the complete `of` argument.
# Postfix indexing belongs to the RHS; infix + does not (it parses as
# `(load_file of "a") + "b.eigs"`), but both make the exact load shape opaque.
cat > "$TMP/leaf.eigs" <<'EIGS'
print of (report of history_value)
EIGS
cat > "$TMP/leaf.eigsX" <<'EIGS'
decoy is 1
EIGS

continuation_case() {
    label=$1
    expression=$2
    cat > "$TMP/continuation_mid.eigs" <<EOF2
$expression
EOF2
    cat > "$TMP/continuation_host.eigs" <<EOF2
history_value is 1.0
history_value is 2.0
history_value is 4.0
history_value is 8.0
load_file of "$TMP/continuation_mid.eigs"
EOF2
    out=$(EIGS_OBS_GATE_STATS=1 "$EIGS" "$TMP/continuation_host.eigs" 2>&1) || {
        printf '%s\n' "$out" >&2
        fail "$label raised instead of preserving observer history"
    }
    printf '%s\n' "$out" | grep -q 'obs-gate: observed' || fail "$label did not arm the gate"
    printf '%s\n' "$out" | grep -q '^moving$' || fail "$label did not load the observer-reading leaf"
    ok "$label arms before the parent's assignments"
}

continuation_case "parenthesized postfix literal" \
    "load_file of (\"$TMP/leaf.eigsX\")[0:-1]"
continuation_case "unparenthesized postfix literal" \
    "load_file of \"$TMP/leaf.eigsX\"[0:-1]"

cat > "$TMP/binary_mid.eigs" <<EOF2
define optional() as:
    return load_file of "$TMP/leaf.eigsX" + "b.eigs"
EOF2
cat > "$TMP/binary_host.eigs" <<EOF2
load_file of "$TMP/binary_mid.eigs"
print of "binary-ok"
EOF2
binary_out=$(EIGS_OBS_GATE_STATS=1 "$EIGS" "$TMP/binary_host.eigs" 2>&1) || fail "binary continuation control did not execute"
printf '%s\n' "$binary_out" | grep -q 'obs-gate: observed' || fail "binary continuation did not make the lazy module opaque"
printf '%s\n' "$binary_out" | grep -q '^binary-ok$' || fail "binary continuation host did not execute"
ok "binary continuation arms even though its function is uncalled"
