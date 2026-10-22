echo "[8i] Equilibrium one-direction trend guard (#1891)"
check_eigs_suite "equilibrium trend guard: direction, neutral zeros, underflow, and balanced exceptions" \
    "test_equilibrium_trend.eigs" "EQUILIBRIUM_TREND_ALL_PASS"
echo ""
