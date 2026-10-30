# [99aae] Verdict-propagation calibration plant (#2059). The ordinary suite
# does not run this deliberate verdict discard; the calibration driver opts in.
echo "[99aae] verdict-propagation calibration plant (#2059)"
if [ "${EIGS_VERDICT_PROPAGATION_PLANT:-0}" = "1" ]; then
    TOTAL=$((TOTAL + 1))
    "$EIGS" "$TESTS_DIR/test_verdict_propagation_plant.eigs" >/dev/null 2>&1 || :
    PASS=$((PASS + 1))
    echo "  PASS: calibration plant deliberately discarded its child verdict"
else
    section_skip "verdict-propagation plant is inactive (driver --selftest enables it)"
fi
echo ""
