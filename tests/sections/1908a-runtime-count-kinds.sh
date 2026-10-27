echo "[1908a] Runtime-published counts and indices are ints (S9-K1, #1758)"
check_eigs_suite "runtime count and index kinds" test_runtime_counts.eigs "All tests passed"
EIGS_STRICT=0 check_eigs_suite "runtime count and index kinds, non-strict" test_runtime_counts.eigs "All tests passed"
