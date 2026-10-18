# [0fm] Sibling expressions release parser chain depth (#1655).
echo "[0fm] Parser expression depth (#1655)"
TOTAL=$((TOTAL + 1))
PED_OUTPUT=$(python3 "$TESTS_DIR/test_parser_expression_depth.py" 2>&1); PED_RC=$?
if [ "$PED_RC" -eq 0 ]; then
    PASS=$((PASS + 1)); echo "  PASS: flat expressions and parser depth boundaries"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: parser expression depth (rc=$PED_RC)"
    printf '%s\n' "$PED_OUTPUT" | sed 's/^/      /'
fi
echo ""
