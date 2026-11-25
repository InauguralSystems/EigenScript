echo "[42m2] Non-finite buffer stores are refused at every index type (#2528)"
TOTAL=$((TOTAL + 1))
nf_store_out=$(python3 "$TESTS_DIR/test_buffer_store_nonfinite_2528.py" "$EIGS" 2>&1)
nf_store_rc=$?
if rc_ok "$nf_store_rc" "$nf_store_out" && [ "$nf_store_rc" -eq 0 ] &&
   grep -qE '^ROWS: buffer store nonfinite examined=35[01] failures=0$' <<< "$nf_store_out"; then
    PASS=$((PASS + 1)); echo "  PASS: buffer stores refuse inf, -inf and nan and keep the old cell"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: non-finite buffer stores"
    printf '%s\n' "$nf_store_out" | tail -20 | sed 's/^/    /'
fi
