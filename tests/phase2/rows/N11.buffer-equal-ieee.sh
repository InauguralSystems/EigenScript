# ROW: N11.buffer-equal-ieee
# ITEMS: N11
# EXPECT-RC: 0
# SHAPE: S
# WITNESS: none
# OPS:
# R1.6z-D1: sgd_update stores infinities and NaN in real program buffers.
set -eu
for strict in 0 1; do
    EIGS_STRICT=$strict "$1" "$(dirname "$0")/../fixtures/r16z-buffer-equal.eigs"
done
