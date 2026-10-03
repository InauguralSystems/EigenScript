echo "[0f6] Intern-name ownership (#1463)"
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
INTERN_OUT=$(bash "$TESTS_DIR/test_intern_owners.sh" 2>&1); INTERN_RC=$?
if [[ "$INTERN_RC" -eq 0 ]] && grep -q '^intern owner structural: 32 passed, 0 failed (32 declared)$' <<< "$INTERN_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: exact intern origins and lifetime-bound owners (32 checks)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: intern ownership (rc=$INTERN_RC)"
    printf '%s\n' "$INTERN_OUT" | sed 's/^/      /'
fi
echo ""
