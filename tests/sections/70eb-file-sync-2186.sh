echo "[70eb] Durable file and directory sync (#2186)"
HOOK_EIGS="$TESTS_DIR/../build/test/eigenscript_fsync_hooks"
if [ ! -x "$HOOK_EIGS" ]; then
    section_skip "fsync reachability needs the make-built EIGS_TEST_HOOKS binary (build.sh lanes do not build test variants)"
    return
fi
TOTAL=$((TOTAL + 1))
OUT=$(EIGS="$EIGS" HOOK_EIGS="$HOOK_EIGS" bash "$TESTS_DIR/test_file_sync.sh" 2>&1); RC=$?
CHECKS=$(printf '%s\n' "$OUT" | grep -c '^PASS:' || true)
if [ "$RC" -eq 0 ] && [ "$CHECKS" -eq 5 ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1)); echo "  FAIL: file sync contract (rc=$RC checks=$CHECKS)"
fi
printf '%s\n' "$OUT"
echo ""
