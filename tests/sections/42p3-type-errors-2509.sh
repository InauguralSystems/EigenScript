echo "[42p3] Wrong-typed builtin argument census (#2509)"
TOTAL=$((TOTAL + 1))
type_2509_out=$(python3 "$TESTS_DIR/type_errors_2509.py" --check "$EIGS" 2>&1)
type_2509_rc=$?
if rc_ok "$type_2509_rc" "$type_2509_out" && [ "$type_2509_rc" -eq 0 ] &&
   grep -q '^PASS: type_errors_2509 examined=' <<< "$type_2509_out"; then
    PASS=$((PASS + 1)); echo "  PASS: wrong-typed builtin arguments raise or have documented classifications"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: wrong-typed builtin argument census"
    echo "$type_2509_out" | sed 's/^/    /'
fi
