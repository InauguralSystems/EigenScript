# ROW: T1.twice-inf
# ITEMS: T1
# EXPECT-RC: 0
# SHAPE: S
# WITNESS: none
# OPS:
# TIERS: off default osr
set -eu
bin=$1
scratch=$(mktemp -d "${TMPDIR:-/tmp}/eigs-r25-tape.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"
cat > p.eigs <<'EOF'
x is 1e308 * 10
y is -x
print of [x, y]
EOF
"$bin" p.eigs > live.out
EIGS_TRACE=t1.tape "$bin" p.eigs > record.out
EIGS_TRACE=t2.tape "$bin" p.eigs > record2.out
cmp t1.tape t2.tape
cmp live.out record.out
cmp live.out record2.out
printf 'tapes identical\n'
EIGS_REPLAY=t1.tape EIGS_REPLAY_STRICT=1 "$bin" p.eigs > replay.out
cmp live.out replay.out
printf 'replay identical\n'
grep -Fx 'A 0 x=inf' t1.tape
grep -Fx 'A 0 y=-inf' t1.tape
