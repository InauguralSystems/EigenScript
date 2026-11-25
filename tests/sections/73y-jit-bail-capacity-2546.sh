echo "[73y] JIT patch-table reservations: one row for each of 30 ops (#2546)"
if [ "$JIT_BACKEND" = jit-backend=none ]; then
    section_skip "JIT n/a (no backend): reservation plants require the x86-64 JIT"
else
TOTAL=$((TOTAL + 1))
jit_capacity_log=$(mktemp "${TMPDIR:-/tmp}/eigs-2546-section.XXXXXX")
EIGS="$EIGS" bash "$TESTS_DIR/test_jit_bail_capacity_2546.sh" >"$jit_capacity_log" 2>&1
jit_capacity_rc=$?
jit_capacity_out=$(cat "$jit_capacity_log")
rm -f "$jit_capacity_log"
if rc_ok "$jit_capacity_rc" "$jit_capacity_out" && [ "$jit_capacity_rc" -eq 0 ] &&
   [ "$(printf '%s\n' "$jit_capacity_out" | grep -c '^PASS:')" -eq 34 ]; then
    PASS=$((PASS + 1)); echo "  PASS: the 34 rows of test_jit_bail_capacity_2546.sh"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: JIT patch-table rows"
    printf '%s\n' "$jit_capacity_out" | sed 's/^/    /'
fi
fi
