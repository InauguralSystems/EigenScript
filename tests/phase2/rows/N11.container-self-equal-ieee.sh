# ROW: N11.container-self-equal-ieee
# ITEMS: N11
# EXPECT-RC: 0
# SHAPE: S
# WITNESS: none
# OPS:
# R1.6z-D2: raw SGD stores NaN; self-comparison follows it through containers.
# The 40-level shared DAG is the cost witness; the row timeout is 30 seconds.
set -eu
for strict in 0 1; do
    EIGS_STRICT=$strict "$1" "$(dirname "$0")/../fixtures/r16z-container-self-equal.eigs"
done
