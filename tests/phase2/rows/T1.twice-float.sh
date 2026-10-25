# ROW: T1.twice-float
# ITEMS: T1
# EXPECT-RC: 0
# SHAPE: S
# WITNESS: none
# OPS: 
# TIERS: off default osr
set -eu
bin=$1
scratch=$(mktemp -d /tmp/eigs-r17-tape.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"
rm -f t1.tape t2.tape
cat > p.eigs <<'EOF'
x is 3.0
y is 0.1 + 0.2
z is -0.0
w is 0.1
print of [x, y, z, w]
EOF
"$bin" p.eigs > live.out
EIGS_TRACE=t1.tape "$bin" p.eigs > record.out
EIGS_TRACE=t2.tape "$bin" p.eigs > record2.out
cmp t1.tape t2.tape
cmp live.out record.out
cmp live.out record2.out
printf 'tapes identical
'
EIGS_REPLAY=t1.tape EIGS_REPLAY_STRICT=1 "$bin" p.eigs > replay.out
cmp live.out replay.out
printf 'replay identical
'
sed -n '/^A [0-9][0-9]* x=/p; /^A [0-9][0-9]* y=/p; /^A [0-9][0-9]* z=/p; /^A [0-9][0-9]* w=/p' t1.tape
