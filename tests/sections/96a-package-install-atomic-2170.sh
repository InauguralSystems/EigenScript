echo "[96a] Atomic package install interruptions (#2170)"
TOTAL=$((TOTAL + 1))
OUT=$(EIGENSCRIPT="$EIGS" bash "$TESTS_DIR/test_pkg_install_atomic.sh" 2>&1); RC=$?
CHECKS=$(printf '%s\n' "$OUT" | grep -c '^PASS:' || true)
if [ "$RC" -eq 0 ] && [ "$CHECKS" -eq 5 ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1)); echo "  FAIL: atomic package install (rc=$RC checks=$CHECKS)"
fi
printf '%s\n' "$OUT"
echo ""
