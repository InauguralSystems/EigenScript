# ROW: N13.vm-buffer-iter-data
# ITEMS: N13
# EXPECT-RC: 0
# SHAPE: S
# WITNESS: none
# OPS:
# R1.6d-D1: get_at oracle; 60 finite calls warm the same function first.
# Semantic tier row; native path is separately killed by the JIT-helper plant.
set -eu
for strict in 0 1; do
    EIGS_STRICT=$strict "$1" "$(dirname "$0")/../fixtures/r16z-vm-iter.eigs"
done
