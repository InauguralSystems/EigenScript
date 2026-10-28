#!/bin/bash
# #1749: a replayed run can itself be recorded without losing served inputs.
set -u

TESTS_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
EIGS=${EIGS:-"$(CDPATH= cd -- "$TESTS_DIR/.." && pwd)/src/eigenscript"}
TMPDIR=$(mktemp -d -t eigs_replay_record.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

cat >"$TMPDIR/replay-record.eigs" <<'EOF'
seed_random of 7
r is random of null
print of (r > 0)
EOF

EIGS_TRACE="$TMPDIR/t1.tape" "$EIGS" "$TMPDIR/replay-record.eigs" >/dev/null
EIGS_REPLAY="$TMPDIR/t1.tape" EIGS_TRACE="$TMPDIR/t2.tape" \
    "$EIGS" "$TMPDIR/replay-record.eigs" >/dev/null

n1=$(awk '$1 == "N" { n++ } END { print n + 0 }' "$TMPDIR/t1.tape")
n2=$(awk '$1 == "N" { n++ } END { print n + 0 }' "$TMPDIR/t2.tape")
if [ "$n1" -eq 1 ] && [ "$n2" -eq 1 ] && cmp -s "$TMPDIR/t1.tape" "$TMPDIR/t2.tape"; then
    echo "PASS: replay while recording retains every served record byte-identically"
    exit 0
fi

echo "FAIL: replay/record tapes differ (decoded N counts: t1=$n1 t2=$n2)"
cmp "$TMPDIR/t1.tape" "$TMPDIR/t2.tape" || true
exit 1
