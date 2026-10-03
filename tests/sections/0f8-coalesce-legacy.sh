echo "[0f8] Coalesce explicit compatibility values (#1398)"
EIGS_STRICT=0 check_eigs_suite "coalesce compatibility retains the legacy result" test_coalesce_legacy.eigs "All tests passed"
echo ""
