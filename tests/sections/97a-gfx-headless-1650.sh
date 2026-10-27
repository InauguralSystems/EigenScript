# [97a] The launcher used by every window-creating gfx suite row is tested
# with a recording stub, including a planted regression (#1650).
echo "[97a] headless gfx launch contract (#1650)"
TOTAL=$((TOTAL + 1))
GH_OUTPUT=$(bash "$TESTS_DIR/test_gfx_headless.sh" 2>&1); GH_RC=$?
if [ "$GH_RC" -eq 0 ] &&
   grep -q '^GFX HEADLESS: 6 passed, 0 failed$' <<<"$GH_OUTPUT"; then
    PASS=$((PASS + 1))
    printf '%s\n' "$GH_OUTPUT" | sed 's/^/  /'
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: gfx headless launcher contract (rc=$GH_RC)"
    printf '%s\n' "$GH_OUTPUT" | sed 's/^/      /'
fi
unset GH_OUTPUT GH_RC
echo ""
