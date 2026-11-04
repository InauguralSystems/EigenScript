# R31-2: the shared interpreter/JIT backstop preserves #861 runaways and
# does not stall a slowly damped oscillation. Harmonic output is descriptive.
echo "[50m] R31-2 observer-loop stall contract"
SC_OUT=$(python3 ../tests/test_stall_contract.py ./eigenscript 2>&1)
SC_RC=$?
TOTAL=$((TOTAL + 1))
if [ "$SC_RC" -eq 0 ]; then
    echo "  PASS: stall contract in four tiers"
    PASS=$((PASS + 1))
else
    echo "  FAIL: stall contract (rc=$SC_RC)"
    echo "$SC_OUT"
    FAIL=$((FAIL + 1))
fi
echo ""
