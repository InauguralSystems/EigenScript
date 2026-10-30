echo "[47j2] Sparse tensor index ranges and atomic updates (#1889)"
EIGS_JIT_OFF=1 check_eigs_suite "sparse tensor selectors reject out-of-range indices before mutation (interpreter)" \
    "test_index_range_atomic.eigs" "SELECTOR SNAPSHOT ALL PASS"
check_eigs_suite "sparse tensor selectors reject out-of-range indices before mutation (default)" \
    "test_index_range_atomic.eigs" "SELECTOR SNAPSHOT ALL PASS"
EIGS_JIT_OSR_THRESHOLD=1 check_eigs_suite "sparse tensor selectors reject out-of-range indices before mutation (OSR threshold 1)" \
    "test_index_range_atomic.eigs" "SELECTOR SNAPSHOT ALL PASS"
echo ""
