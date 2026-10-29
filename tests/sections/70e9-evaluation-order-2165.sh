echo "[70e9] Evaluation order is identical across interpreter, JIT and OSR (#2165)"
EIGS_JIT_OFF=1 check_eigs_suite "evaluation order: interpreter" test_evaluation_order_2165.eigs "All tests passed"
check_eigs_suite "evaluation order: default JIT" test_evaluation_order_2165.eigs "All tests passed"
EIGS_JIT_OSR_THRESHOLD=1 check_eigs_suite "evaluation order: OSR threshold 1" test_evaluation_order_2165.eigs "All tests passed"
