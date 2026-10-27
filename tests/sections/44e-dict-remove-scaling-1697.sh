echo "[44e] Dict removal scaling (#1697)"
TOTAL=$((TOTAL + 1))
DR_OUTPUT=$(timeout 8 ./eigenscript "$TESTS_DIR/test_dict_remove_scaling.eigs" 2>&1); DR_RC=$?
if [ "$DR_RC" -eq 0 ] && grep -q '^Tests: 1 | Pass: 1 | Fail: 0$' <<< "$DR_OUTPUT"; then
    PASS=$((PASS + 1)); echo "  PASS: 40,000-key removal completes within 8 seconds"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: scaling gate rc=$DR_RC"; printf '%s\n' "$DR_OUTPUT" | tail -10
fi
