# ROW: T1.int-replay-kind
# ITEMS: T1
# EXPECT-RC: 0
# SHAPE: S
# WITNESS: none
# OPS: 
# TIERS: off default osr
set -eu
bin=$1
cat > p.eigs <<'EOF'
r is random_int of [1, 6]
x is 9007199254740993
if r > 3:
    x is 9223372036854775807
print of [num_type of x, x == 9007199254740993 or x == 9223372036854775807]
EOF
EIGS_TRACE=t.tape "$bin" p.eigs > live.out
EIGS_REPLAY=t.tape EIGS_REPLAY_STRICT=1 "$bin" p.eigs > replay.out
cmp live.out replay.out
printf '["int", true]\n' > expect.out
cmp expect.out live.out
printf 'int replay identical\n'
grep -q '^A [0-9][0-9]* x=9007199254740993$' t.tape
printf 'int assignment exact\n'
