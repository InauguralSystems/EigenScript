# ROW: T1.v7-header
# Historical row id; sync #5 combined v7 schemas as v8; sync #10 combines
# phase2 kind tokens and main continuation framing as v9, rejecting both v8s.
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
# Reject a main/phase2 v8 tape before its untyped numeric tokens can be
# parsed with a different kind. Retain the separate v6 refusal fixture too.
sed '1s/^V 9 /V 8 /' t.tape > old-v8.tape
if EIGS_REPLAY=old-v8.tape "$bin" p.eigs > old-v8.out 2> old-v8.err; then
    echo 'v8 replay unexpectedly accepted' >&2
    exit 1
fi
grep -q 'format v8' old-v8.err
