# #1873: literal modules behind uncalled functions use a token-level observer scan.
echo "[70e8] Observer lazy-module token scan (#1873)"
TOTAL=$((TOTAL + 1))
LAZY_SCAN_OUT=$(EIGS="$EIGS" bash "$TESTS_DIR/test_obs_gate_lazy_scan.sh" 2>&1); LAZY_SCAN_RC=$?
if [ "$LAZY_SCAN_RC" -eq 0 ] &&
   [ "$(printf '%s\n' "$LAZY_SCAN_OUT" | grep -c '^PASS:')" -eq 10 ]; then
    PASS=$((PASS + 1)); printf '%s\n' "$LAZY_SCAN_OUT" | sed 's/^/  /'
else
    FAIL=$((FAIL + 1)); echo "  FAIL: lazy observer token scan (rc=$LAZY_SCAN_RC)"
    printf '%s\n' "$LAZY_SCAN_OUT" | sed 's/^/    /'
fi
