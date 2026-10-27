echo "[99sa] Strict differential renderer probe (#1825)"
TOTAL=$((TOTAL + 1))
RP_OUT=$(bash "$TESTS_DIR/test_strict_renderer_probe.sh" 2>&1); RP_RC=$?
if [ "$RP_RC" -eq 0 ] && rc_ok "$RP_RC" "$RP_OUT"; then
    PASS=$((PASS + 1))
    echo "  PASS: true enables pixels, false skips, and invalid output fails closed"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: renderer probe is not a strict boolean gate (rc=$RP_RC)"
fi
printf '%s\n' "$RP_OUT"
unset RP_OUT RP_RC
echo ""
