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
echo "  embed multi-attach intern lifetime (#1162)"
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
MULTIATTACH_OUT=$(bash "$TESTS_DIR/test_embed_multiattach.sh" 2>&1); MULTIATTACH_RC=$?
if [[ "$MULTIATTACH_RC" -eq 0 ]] &&
   [[ $(grep -c '^PASS: embed multi-attach preserves dict keys, global bindings, and builtins$' <<< "$MULTIATTACH_OUT") -eq 1 ]]; then
    PASS=$((PASS + 1)); echo "  PASS: attachment-owned names survive for the next host thread"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: embed multi-attach intern lifetime (rc=$MULTIATTACH_RC)"
    printf '%s\n' "$MULTIATTACH_OUT" | sed 's/^/      /'
fi
echo ""
