echo "[73z] sign_extend masks to its declared width (#1896)"
TOTAL=$((TOTAL + 1))
SE1896_OUT=$(EIGS_JIT_OFF=1 "$EIGS" "$TESTS_DIR/test_sign_extend_1896.eigs" 2>&1)
SE1896_RC=$?
if rc_ok "$SE1896_RC" "$SE1896_OUT" && [ "$SE1896_RC" -eq 0 ] &&
   [ "$(printf '%s\n' "$SE1896_OUT" | grep -c '^PASS:')" -eq 13 ]; then
    PASS=$((PASS + 1)); echo "  PASS: all thirteen width, boundary, and compatibility cases"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: sign_extend contract regression"
    printf '%s\n' "$SE1896_OUT" | sed 's/^/    /'
fi
