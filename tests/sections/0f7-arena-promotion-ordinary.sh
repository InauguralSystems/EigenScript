echo "[0f7] Ordinary acyclic arena promotion (#1588)"
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
ARENA_PROMOTION_OUT=$(EIGENSCRIPT=./eigenscript bash "$TESTS_DIR/test_arena_promotion_ordinary.sh" 2>&1); ARENA_PROMOTION_RC=$?
if [ "$ARENA_PROMOTION_RC" -eq 0 ] && rc_ok "$ARENA_PROMOTION_RC" "$ARENA_PROMOTION_OUT" && [ "$(grep -Fxc 'ordinary arena promotion: 20 passed, 0 failed (20 declared)' <<< "$ARENA_PROMOTION_OUT")" -eq 1 ]; then
    PASS=$((PASS + 1)); echo "  PASS: finite acyclic promotion and serial candidate ownership"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: ordinary arena promotion (rc=$ARENA_PROMOTION_RC)"
    printf '%s\n' "$ARENA_PROMOTION_OUT" | sed 's/^/      /'
fi
echo ""
