echo "[70eb] Durable file and directory sync (#2186)"
TOTAL=$((TOTAL + 1))
OUT=$(EIGS="$EIGS" bash "$TESTS_DIR/test_file_sync.sh" 2>&1); RC=$?
CHECKS=$(printf '%s\n' "$OUT" | grep -c '^PASS:' || true)
if [ "$RC" -eq 0 ] && [ "$CHECKS" -eq 4 ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1)); echo "  FAIL: file sync contract (rc=$RC checks=$CHECKS)"
fi
printf '%s\n' "$OUT"
echo ""
