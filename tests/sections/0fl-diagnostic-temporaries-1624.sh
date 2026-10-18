echo "[0fl] Owned diagnostic temporaries (#1624)"
TOTAL=$((TOTAL + 1))
if bash "$TESTS_DIR/test_diagnostic_capture.sh"; then
    PASS=$((PASS + 1))
    echo "  PASS: diagnostic capture honors TMPDIR and fails closed"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: diagnostic capture temporary-file handling"
fi
echo ""
