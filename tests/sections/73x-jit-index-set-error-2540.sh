echo "[73x] JIT helper errors stop native execution (#2540)"
TOTAL=$((TOTAL + 1))
jit_2540_log=$(mktemp "${TMPDIR:-/tmp}/eigs-2540-section.XXXXXX")
EIGS="$EIGS" bash "$TESTS_DIR/test_jit_index_set_error_2540.sh" >"$jit_2540_log" 2>&1
jit_2540_rc=$?
jit_2540_out=$(cat "$jit_2540_log")
rm -f "$jit_2540_log"
if rc_ok "$jit_2540_rc" "$jit_2540_out" && [ "$jit_2540_rc" -eq 0 ] &&
   [ "$(printf '%s\n' "$jit_2540_out" | grep -c '^PASS:')" -eq 20 ] &&
   printf '%s\n' "$jit_2540_out" | grep -qxF 'examined=20'; then
    PASS=$((PASS + 1)); echo "  PASS: twenty cases match their literal results with the JIT on and off"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: JIT error-bailout regression"
    printf '%s\n' "$jit_2540_out" | sed 's/^/    /'
fi
