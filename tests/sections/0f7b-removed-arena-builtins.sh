echo "[0f7b] Removed arena builtins are undefined (#1665)"
REMOVED_ARENA_OUT=$(./eigenscript -e 'arena_mark of null' 2>&1)
REMOVED_ARENA_RC=$?
TOTAL=$((TOTAL + 1))
if [ "$REMOVED_ARENA_RC" -ne 0 ] && [ "$(grep -Fxc "Error line 1: undefined variable 'arena_mark'" <<< "$REMOVED_ARENA_OUT")" -eq 1 ]; then
    PASS=$((PASS + 1)); echo "  PASS: arena_mark fails with the normal undefined-name error"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: arena_mark removal (rc=$REMOVED_ARENA_RC)"
    printf '%s\n' "$REMOVED_ARENA_OUT" | sed 's/^/      /'
fi
echo ""
