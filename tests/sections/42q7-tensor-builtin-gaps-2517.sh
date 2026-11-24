echo "[42q7] Tensor builtin silent-answer regressions (#2517, #2514)"
TOTAL=$((TOTAL + 1))
tensor_gap_out=$(EIGS="$EIGS" python3 "$TESTS_DIR/tensor_builtin_gaps_2517.py" 2>&1)
tensor_gap_rc=$?
if rc_ok "$tensor_gap_rc" "$tensor_gap_out" && [ "$tensor_gap_rc" -eq 0 ] &&
   [ "$(printf '%s\n' "$tensor_gap_out" | grep -c '^PASS: tensor builtin gaps EIGS_STRICT=')" -eq 3 ]; then
    PASS=$((PASS + 1)); echo "  PASS: SGD guards are atomic and tensor_load raises io"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: tensor builtin regression checks"
    printf '%s\n' "$tensor_gap_out" | sed 's/^/    /'
fi
