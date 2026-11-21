# ROW: T1.twice-int
# ITEMS: T1
# EXPECT-RC: 0
# SHAPE: S
# WITNESS: none
# OPS: 
# TIERS: off default osr
set -eu
bin=$1
cat > p.eigs <<'EOF'
define sq(x) as:
    return x * x
x is 9007199254740993
y is sq of 94906267
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
sed -n '/^A [0-9][0-9]* x=/p; /^A [0-9][0-9]* y=/p' t1.tape
