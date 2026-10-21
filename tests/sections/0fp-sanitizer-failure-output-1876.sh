echo "[0fp] Sanitizer failure excerpts (#1876)"
TOTAL=$((TOTAL + 1))
if bash "$TESTS_DIR/test_failure_output.sh"; then
    PASS=$((PASS + 1))
    echo "  PASS: failure excerpts retain sanitizer diagnostics and the captured tail"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: failure excerpt regression checks"
fi
echo ""
