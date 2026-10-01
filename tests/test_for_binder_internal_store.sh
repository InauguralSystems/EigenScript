#!/usr/bin/env bash
# #1384: compiler-only for-binder save/restore stores are invisible to users.

PASS=0
FAIL=0
EIGS=./eigenscript
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs_for_internal_XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

cat > "$TMP/tape.eigs" <<'EOF'
define f(i) as:
    for i in [1, 2]:
        x is i
        y is 0
    return i
print of (f of 0)
EOF

EIGS_TRACE="$TMP/trace.tape" "$EIGS" "$TMP/tape.eigs" > "$TMP/tape.out" 2>&1
RC=$?
if [ "$RC" -eq 0 ] && [ "$(cat "$TMP/tape.out")" = "0" ]; then
    ok "for binder restores the existing function binding"
else
    bad "taped binder program exits cleanly and prints restored value (rc=$RC, out=$(cat "$TMP/tape.out"))"
fi

if grep -q '^A __for_save=' "$TMP/trace.tape"; then
    bad "trace tape hides the compiler's __for_save slot"
else
    ok "trace tape hides the compiler's __for_save slot"
fi

# Only the two source-level binder assignments belong on the tape.  A third
# `A i=` would be the compiler's post-loop restore masquerading as source.
I_RECORDS=$(grep -c '^A i=' "$TMP/trace.tape" 2>/dev/null); I_RECORDS=${I_RECORDS:-0}
if [ "$I_RECORDS" -eq 2 ]; then
    ok "trace tape omits the compiler's binder restore"
else
    bad "trace tape has $I_RECORDS i assignments (want the two loop binds)"
fi

cat > "$TMP/temporal.eigs" <<'EOF'
define f(i) as:
    for i in [1, 2]:
        x is i
        y is 0
    return [(what is i at 2), (what is i at 4), i]
print of (f of 0)
i is 0
for i in [1, 2]:
    x is i
    y is 0
print of [(what is i at 9), (what is i at 11), i]
EOF

TEMPORAL_OUT=$("$EIGS" "$TMP/temporal.eigs" 2>&1); TEMPORAL_RC=$?
EXPECTED='[2, 2, 0]
[2, 2, 0]'
if [ "$TEMPORAL_RC" -eq 0 ] && [ "$TEMPORAL_OUT" = "$EXPECTED" ]; then
    ok "function and module binder restores have identical temporal answers"
else
    bad "temporal scope parity (rc=$TEMPORAL_RC, got: $TEMPORAL_OUT)"
fi

echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
