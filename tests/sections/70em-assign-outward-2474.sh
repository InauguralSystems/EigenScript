echo "[70em] An assignment lands outside whatever the function reads (#2474)"
AO2474_OUT=$(EIGS="$EIGS" python3 "$TESTS_DIR/test_assign_outward_2474.py" 2>&1); AO2474_RC=$?
printf '%s\n' "$AO2474_OUT" | sed 's/^/  /'
TOTAL=$((TOTAL + 1))
if rc_ok "$AO2474_RC" "$AO2474_OUT" && grep -qxF 'examined=3280 failed=0' <<< "$AO2474_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: the assignment matrix in every setting"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: the assignment matrix (rc=$AO2474_RC)"
fi
unset AO2474_OUT AO2474_RC
echo ""
