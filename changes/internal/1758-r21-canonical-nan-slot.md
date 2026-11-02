Canonicalize every NaN payload at the single double-to-slot writer, so host
double bits cannot masquerade as a tagged value. The C slot test covers every
tag family, signaling/sign/payload controls and actual refcount operations.
This R2.1 memory-safety change retains the existing scalar numeric guard.
