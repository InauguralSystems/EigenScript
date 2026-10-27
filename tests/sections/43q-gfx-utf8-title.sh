echo "[43q] X11 UTF-8 window title (#1681)"
GUT_OUTPUT=$(bash "$TESTS_DIR/test_gfx_utf8_title.sh" 2>&1); GUT_RC=$?
TOTAL=$((TOTAL + 1))
if [ "$GUT_RC" -eq 0 ] && rc_ok "$GUT_RC" "$GUT_OUTPUT" &&
   grep -q '^  PASS: xprop reads the UTF-8 title bytes from _NET_WM_NAME$' <<< "$GUT_OUTPUT"; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi
printf '%s\n' "$GUT_OUTPUT"
unset GUT_OUTPUT GUT_RC
echo ""

echo "[43r] gfx LC_CTYPE replay determinism (#1681)"
GCL_OUTPUT=$(bash "$TESTS_DIR/test_gfx_ctype_locale.sh" 2>&1); GCL_RC=$?
TOTAL=$((TOTAL + 1))
if [ "$GCL_RC" -eq 0 ] && rc_ok "$GCL_RC" "$GCL_OUTPUT" &&
   grep -q '^  PASS: gfx leaves byte-oriented ctype answers replay-deterministic$' <<< "$GCL_OUTPUT" &&
   grep -q '^  PASS: LC_CTYPE after SDL loading is C.UTF-8$' <<< "$GCL_OUTPUT"; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi
printf '%s\n' "$GCL_OUTPUT"
unset GCL_OUTPUT GCL_RC
echo ""
