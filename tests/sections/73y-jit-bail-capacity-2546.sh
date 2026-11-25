echo "[73y] JIT reservation/write coupling (#2546)"
TOTAL=$((TOTAL + 1))
jit_capacity_log=$(mktemp "${TMPDIR:-/tmp}/eigs-2546-section.XXXXXX")
EIGS="$EIGS" bash "$TESTS_DIR/test_jit_bail_capacity_2546.sh" >"$jit_capacity_log" 2>&1
jit_capacity_rc=$?
jit_capacity_out=$(cat "$jit_capacity_log")
rm -f "$jit_capacity_log"
if rc_ok "$jit_capacity_rc" "$jit_capacity_out" && [ "$jit_capacity_rc" -eq 0 ] &&
   [ "$(printf '%s\n' "$jit_capacity_out" | grep -c '^PASS:')" -eq 3 ]; then
    PASS=$((PASS + 1)); echo "  PASS: all reservations and writes use the checked protocol"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: JIT reservation/write coupling"
    printf '%s\n' "$jit_capacity_out" | sed 's/^/    /'
fi
