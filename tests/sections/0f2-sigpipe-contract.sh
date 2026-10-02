echo "[0f2] Host SIGPIPE contract (#1151)"
check_binary_fingerprint
TOTAL=$((TOTAL + 1))
SIGPIPE_OUT=$(EIGENSCRIPT=./eigenscript bash "$TESTS_DIR/test_sigpipe_contract.sh" 2>&1); SIGPIPE_RC=$?
if rc_ok "$SIGPIPE_RC" "$SIGPIPE_OUT" && grep -q '^SIGPIPE contract: 10 passed, 0 failed (10 declared)$' <<< "$SIGPIPE_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: subprocess/HTTP calls preserve SIGPIPE and closed stdout is reported"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: host SIGPIPE contract (rc=$SIGPIPE_RC)"
    printf '%s\n' "$SIGPIPE_OUT" | sed 's/^/      /'
fi
echo ""
