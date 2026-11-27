echo "[70eo] stats/lab real-valued statistics on large ints (#2497; interpreter/JIT/OSR)"
EIGS_JIT_OFF=1 check_eigs_suite "stats large ints: interpreter" test_stats_large_ints_2497.eigs "All tests passed."
check_eigs_suite "stats large ints: default" test_stats_large_ints_2497.eigs "All tests passed."
EIGS_JIT_OSR_THRESHOLD=1 check_eigs_suite "stats large ints: OSR" test_stats_large_ints_2497.eigs "All tests passed."
