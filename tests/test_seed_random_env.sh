#!/usr/bin/env bash
echo "PLAN: 6"
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
rc=0
EIGS_SEED_RANDOM= "$EIGS" "$T/draw.eigs" > "$T/empty.out" 2> "$T/empty.err" || rc=$?
[ "$rc" -eq 0 ] || fail "empty seed exited $rc, want 0 (unset semantics)"
[ ! -s "$T/empty.err" ] || fail "empty seed wrote a startup diagnostic"
[ "$(wc -l < "$T/empty.out" | tr -d ' ')" -eq 2 ] || fail "empty seed did not run both unseeded draws"
pass "empty seed is treated as unset and permits unseeded draws"
# Seeds outside 0..2^32-1 (#2566): the CLI must hand all 64 bits to
# seed_random's path. A planted (uint32_t) cast or an `int seed` in src/main.c
# turns at least one of these red; both cases were green before this row.
# INT64_MIN is written as an int expression (the literal 2^63 lexes as a float).
for wide in -1 4294967297 -9223372036854775808; do
    lit=$wide; [ "$wide" = -9223372036854775808 ] && lit='(0 - 9223372036854775807) - 1'
    { printf 'seed_random of (%s)\n' "$lit"; cat "$T/draw.eigs"; } > "$T/script_seed.eigs"
    "$EIGS" "$T/script_seed.eigs" > "$T/script.out" || fail "seed_random of $wide failed"
    EIGS_SEED_RANDOM=$wide "$EIGS" "$T/draw.eigs" > "$T/env.out" || fail "EIGS_SEED_RANDOM=$wide failed"
    [ "$(wc -l < "$T/env.out" | tr -d ' ')" -eq 2 ] || fail "EIGS_SEED_RANDOM=$wide did not draw twice"
    cmp "$T/script.out" "$T/env.out" >/dev/null || fail "EIGS_SEED_RANDOM=$wide differs from seed_random of $wide: $(tr '\n' ' ' < "$T/env.out") vs $(tr '\n' ' ' < "$T/script.out")"
done
pass "EIGS_SEED_RANDOM of -1, 4294967297 and INT64_MIN draws seed_random's stream"
