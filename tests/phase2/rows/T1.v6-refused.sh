# ROW: T1.v6-refused
# ITEMS: T1
# EXPECT-RC: 0
# SHAPE: S
# WITNESS: none
# OPS: 
# TIERS: off default osr
set -eu
bin=$1
printf 'print of 3\n' > p.eigs
# Start with a tape stamped by this binary so only the format differs.
EIGS_TRACE=current.tape "$bin" p.eigs > live.out
sed '1s/^V [0-9][0-9]* /V 6 /' current.tape > v6.tape
rc=0
EIGS_REPLAY=v6.tape EIGS_REPLAY_STRICT=1 "$bin" p.eigs > replay.out 2> replay.err || rc=$?
if [ "$rc" -eq 0 ]; then
    printf 'v6 accepted\n'
    exit 1
fi
grep -q 'format v6' replay.err
printf 'rc!=0 names-6\n'
