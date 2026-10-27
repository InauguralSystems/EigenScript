#!/usr/bin/env bash
set -u

EIGS=${EIGS:-$(cd "$(dirname "$0")/.." && pwd)/src/eigenscript}
T=$(mktemp -d -t eigs-1750.XXXXXX) || exit 2
trap 'rm -rf "$T"' EXIT

cat > "$T/refusals.eigs" <<'EOF'
seed_random of 3
for a in [["x", 1.0], [2, "y"], ["x", 2, 1.0], [2, "x", 1.0], [2, 2, "s"]]:
    try:
        r is random_normal of a
        print of f"ok {a} -> {len of r}"
    catch e:
        print of f"raised {a}: {e["kind"]} {e["message"]}"
EOF

EIGS_TRACE="$T/refusals.tape" "$EIGS" "$T/refusals.eigs" > "$T/record" 2>&1
record_rc=$?
EIGS_REPLAY="$T/refusals.tape" EIGS_REPLAY_STRICT=1 \
    "$EIGS" "$T/refusals.eigs" > "$T/replay" 2>&1
replay_rc=$?

raises=$(grep -c '^raised .*: type_mismatch random_normal: expected a number, got str$' "$T/record" || true)
records=$(grep -c '^N .* random_normal=' "$T/refusals.tape" || true)
if [ "$record_rc" -eq 0 ] && [ "$replay_rc" -eq 0 ] &&
   [ "$raises" -eq 5 ] && [ "$records" -eq 0 ] &&
   cmp -s "$T/record" "$T/replay"; then
    echo "  PASS: all five random_normal type refusals replay byte-identically"
    echo "ISSUE_1750: 1 passed, 0 failed"
    exit 0
fi

echo "  FAIL: random_normal type refusals did not replay byte-identically"
echo "ISSUE_1750: 0 passed, 1 failed"
echo "record rc=$record_rc; replay rc=$replay_rc; raises=$raises; tape records=$records"
echo "--- recorded"; cat "$T/record"
echo "--- replayed"; cat "$T/replay"
exit 1
