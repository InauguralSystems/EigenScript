echo "[99ad] Cold omitted-capability diagnostics (#1415/#1159)"
TOTAL=$((TOTAL + 1))
MC_OUTPUT=$(bash "$TESTS_DIR/test_missing_capability.sh" 2>&1); MC_RC=$?
if [ "$MC_RC" -eq 0 ] && rc_ok "$MC_RC" "$MC_OUTPUT" &&
    [ "$(grep -c '^PASS: missing capability strict=' <<< "$MC_OUTPUT")" -eq 9 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: compiled-name population, resolution, shadowing and discovery"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: cold omitted-capability contract (rc=$MC_RC)"
fi
printf '%s\n' "$MC_OUTPUT"
echo ""
