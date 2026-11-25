echo "[7q1] The stores of #2528's hot function and loop at indexes 0.0 and -2.0 are native (#2541)"
jit_scan_out=$(python3 "$TESTS_DIR/test_jit_scan_end_2541.py" "$EIGS" 2>&1)
jit_scan_rc=$?
if grep -qxF 'SKIP: JIT scan-end pins require a binary with the x86-64 JIT' <<< "$jit_scan_out" && [ "$jit_scan_rc" -eq 0 ]; then
    section_skip "JIT scan-end pins require a binary with the x86-64 JIT"
else
    TOTAL=$((TOTAL + 1))
    if rc_ok "$jit_scan_rc" "$jit_scan_out" && [ "$jit_scan_rc" -eq 0 ] &&
       grep -qxF 'examined=4 failures=0' <<< "$jit_scan_out"; then
        PASS=$((PASS + 1)); echo "  PASS: the compiled prefix of both programs ends where it is pinned, past the stores"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: JIT scan end"
        printf '%s\n' "$jit_scan_out" | sed 's/^/    /'
    fi
fi
