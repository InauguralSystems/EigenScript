# R31-2: elided numeric sampling updates the live slot, never trace history.
echo "[50f] Elided observer history (#1758 R31-2)"
check_eigs_suite "elided temporal triple remains absent" test_unobserved_history_r31.eigs "All tests passed."
echo ""
