echo "[47j6] An SGD step that raises leaves the parameter as it was (#2495)"
check_eigs_suite "sgd_update, its rows and cols variants leave the parameter as it was" \
    "test_sgd_update_refused_2495.eigs" "All tests passed"
check_eigs_suite "sgd_update under EIGS_STRICT=1: a result that is not finite" \
    "test_sgd_update_refused_strict_2495.eigs" "All tests passed"
echo ""
