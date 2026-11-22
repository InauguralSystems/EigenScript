# ROW: T1.float-kind-token
# ITEMS: T1
# EXPECT-RC: 0
# SHAPE: S
# WITNESS: none
# OPS: 
# TIERS: off default osr
set -eu
bin=$1
cat > p.eigs <<'EOF'
x is 3.0
z is -0.0
print of [num_type of x, num_type of z]
EOF
EIGS_TRACE=t.tape "$bin" p.eigs > live.out
grep -q '^A [0-9][0-9]* x=3\.0$' t.tape
grep -q '^A [0-9][0-9]* z=-0\.0$' t.tape
printf 'float tokens marked\n'
EIGS_REPLAY=t.tape EIGS_REPLAY_STRICT=1 "$bin" p.eigs > replay.out
cmp live.out replay.out
printf 'float replay identical\n'
