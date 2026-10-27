# [99acc] Executable-enrolment edge derivation (#1880).
echo "[99acc] executable-enrolment edges"
TOTAL=$((TOTAL + 1))
edge_out=$(bash "$TESTS_DIR/test_enrolment_edges.sh" 2>&1); edge_rc=$?
if [ "$edge_rc" -eq 0 ]; then
    PASS=$((PASS + 1)); printf '%s\n' "$edge_out"
else
    FAIL=$((FAIL + 1)); printf '%s\n' "$edge_out"
fi
echo ""
