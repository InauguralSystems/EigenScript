#!/usr/bin/env bash
echo "PLAN: 4"
set -eu
EIGS=${EIGS:-$(cd "$(dirname "$0")/.." && pwd)/src/eigenscript}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/draw.eigs" <<'EIGS'
print of random of null
print of random_int of [1, 1000000]
EIGS
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }
EIGS_SEED_RANDOM=2120 "$EIGS" "$T/draw.eigs" > "$T/a"
EIGS_SEED_RANDOM=2120 "$EIGS" "$T/draw.eigs" > "$T/b"
cmp "$T/a" "$T/b" >/dev/null || fail "same seed differed between processes"
pass "same seed produces identical process-wide draws"
printf '0.2717224071539057\n413189\n' > "$T/want2120"
cmp "$T/want2120" "$T/a" >/dev/null || fail "seed 2120 first draws changed"
pass "seed 2120 first draws are pinned"
EIGS_SEED_RANDOM=2121 "$EIGS" "$T/draw.eigs" > "$T/actual2121"
printf '0.14252471581949422\n26042\n' > "$T/want2121"
cmp "$T/want2121" "$T/actual2121" >/dev/null || fail "seed 2121 first draws changed"
pass "seed 2121 first draws are pinned"
rc=0; EIGS_SEED_RANDOM=not-an-integer "$EIGS" "$T/draw.eigs" > "$T/bad.out" 2> "$T/bad.err" || rc=$?
[ "$rc" -eq 2 ] || fail "malformed seed exited $rc, want 2 (a startup error)"
grep -F 'EIGS_SEED_RANDOM: invalid integer: not-an-integer' "$T/bad.err" >/dev/null || fail "malformed seed lacked diagnostic"
[ ! -s "$T/bad.out" ] || fail "malformed seed ran program code before failing"
pass "malformed seed is a startup error before any program output"
