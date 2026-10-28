echo "[0fk] Unknown string escapes (#1641)"
check_binary_fingerprint
# Counted like every child .sh (#1354): a bare `bash child` printed PASS lines
# that never reached TOTAL, so the section had no outcome of its own.
TOTAL=$((TOTAL + 1))
ESCAPES_OUT=$(bash "$TESTS_DIR/test_unknown_string_escapes.sh" 2>&1); ESCAPES_RC=$?
if [[ "$ESCAPES_RC" -eq 0 ]] && grep -qx 'unknown escape checks: pass=10 fail=0' <<< "$ESCAPES_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: unknown string escapes rejected with positions, listed escapes accepted (10 checks)"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: unknown string escapes (rc=$ESCAPES_RC)"
    printf '%s\n' "$ESCAPES_OUT" | sed 's/^/      /'
fi
echo ""
