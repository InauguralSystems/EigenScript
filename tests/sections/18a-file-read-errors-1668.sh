echo "[18a] File read errors expose OS reasons (#1668)"
check_binary_fingerprint
FRE_OUTPUT=$(bash "$TESTS_DIR/test_file_read_errors.sh" 2>&1); FRE_RC=$?
TOTAL=$((TOTAL + 1))
if [ "$FRE_RC" -eq 0 ] && rc_ok "$FRE_RC" "$FRE_OUTPUT" &&
   grep -q '^FILE READ ERRORS: 11 passed, 0 failed$' <<< "$FRE_OUTPUT"; then
    PASS=$((PASS + 1))
    echo "  PASS: file read failures raise io with path and strerror reason"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: file read error contract (rc=$FRE_RC)"
fi
printf '%s\n' "$FRE_OUTPUT"
unset FRE_OUTPUT FRE_RC
echo ""
