# ROW: T1.v7-header
# ITEMS: T1
# EXPECT-RC: 0
# SHAPE: S
# WITNESS: none
# OPS: 
# TIERS: off default osr
set -eu
bin=$1
printf 'x is 3\n' > p.eigs
EIGS_TRACE=t.tape "$bin" p.eigs > live.out
head -1 t.tape | cut -d' ' -f1-2
