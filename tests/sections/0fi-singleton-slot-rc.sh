# The null/bool singletons never lose reference counts through a slot (EigenLua warmup fuzz, 2026-10-11).
echo "[0fi] Singleton slot refcounts"
check_eigs_suite "singleton slot refcounts" test_singleton_slot_rc.eigs "All tests passed"
echo ""
