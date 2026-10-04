# #1621: cached calls must start with fresh observer histories/settings.
echo "[70e2] Bounded parked observer storage (#1621)"
EIGS_JIT_OFF=0 EIGS_JIT_ENTRY_THRESHOLD=1 check_eigs_suite "JIT cached-call observer storage" "test_observer_park_storage.eigs" "All tests passed."
EIGS_JIT_OFF=1 check_eigs_suite "VM cached-call observer storage" "test_observer_park_storage.eigs" "All tests passed."
echo ""
