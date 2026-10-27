echo "[47k] Model token id ranges (#1889)"
TOKEN_PROBE=$(mktemp "${TMPDIR:-/tmp}/eigs_token_probe.XXXXXX")
printf '%s\n' 'print of (eigen_model_loaded of null)' > "$TOKEN_PROBE"
TOKEN_OUT=$("$EIGS" "$TOKEN_PROBE" 2>&1); TOKEN_RC=$?
rm -f "$TOKEN_PROBE"
if [ "$TOKEN_RC" -ne 0 ]; then
    section_skip "binary built without EIGENSCRIPT_EXT_MODEL; run this section in the server lane"
else
    TOTAL=$((TOTAL + 1))
    TOKEN_OUT=$(EIGS_BIN="$EIGS" bash "$TESTS_DIR/test_model_token_range.sh" 2>&1); TOKEN_RC=$?
    if [ "$TOKEN_RC" -eq 0 ] && [ "$(printf '%s\n' "$TOKEN_OUT" | grep -c '^  PASS: model token range')" -eq 3 ]; then
        PASS=$((PASS + 1)); echo "  PASS: model token ids raise on all three execution tiers"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: model token id ranges (rc=$TOKEN_RC)"
    fi
    printf '%s\n' "$TOKEN_OUT"
fi
echo ""
