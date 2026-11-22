echo "[47j5] Numerical gradients preserve parameter numeric kinds (#2483)"
check_eigs_suite "numerical gradient restores exact numeric slots" \
    "test_numerical_grad_kinds_2483.eigs" "All tests passed"
echo ""
