# [51b] #1883: module-slot promotion must not split a name-bound binder's
# writes from its reads inside an unobserved block.
echo "[51b] Unobserved Binder Storage (#1883)"
check_eigs_suite "unobserved binders share read/write storage (#1883)" \
    test_unobserved_binders.eigs "All tests passed"
echo ""
