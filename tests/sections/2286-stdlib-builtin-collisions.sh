echo "[2286] Stdlib top-level definitions do not replace builtins (#2286)"
SBC_OUTPUT=$(python3 "$TESTS_DIR/test_issue_2286_stdlib_builtin_collisions.py" 2>&1); SBC_RC=$?
SBC_PASS=$(printf '%s\n' "$SBC_OUTPUT" | grep -c '^PASS:' || true)
SBC_FAIL=$(printf '%s\n' "$SBC_OUTPUT" | grep -c '^FAIL:' || true)
TOTAL=$((TOTAL + SBC_PASS + SBC_FAIL)); PASS=$((PASS + SBC_PASS)); FAIL=$((FAIL + SBC_FAIL))
printf '%s\n' "$SBC_OUTPUT"
if ! rc_ok "$SBC_RC" "$SBC_OUTPUT" || ! child_plan_ok "$SBC_OUTPUT" "$SBC_RC" "^PASS:" "^FAIL:"; then
    FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); echo "FAIL: issue 2286 collision regression summary (rc=$SBC_RC)"
fi
echo ""
