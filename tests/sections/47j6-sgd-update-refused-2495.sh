echo "[47j6] An SGD step reads every cell before it writes one (#2495)"
check_eigs_suite "sgd_update and its rows and cols variants refuse a cell that is not finite before any update" \
    "test_sgd_update_refused_2495.eigs" "All tests passed"
check_eigs_suite "sgd_update and its rows and cols variants under EIGS_STRICT=1: a result that is not finite" \
    "test_sgd_update_refused_strict_2495.eigs" "All tests passed"
echo ""
