echo "[15l] Multi-line binary errors use the operator line (#1425)"
check_binary_fingerprint
for tier in interpreter jit osr; do
    case "$tier" in
        interpreter) operator_line_env=(EIGS_JIT_OFF=1) ;;
        jit) operator_line_env=(EIGS_JIT_HOT=1) ;;
        osr) operator_line_env=(EIGS_JIT_HOT=1 EIGS_JIT_OSR_THRESHOLD=1) ;;
    esac
    operator_line_out=$(env "${operator_line_env[@]}" "$EIGS" "$TESTS_DIR/test_operator_line.eigs" </dev/null 2>&1)
    operator_line_rc=$?
    TOTAL=$((TOTAL + 1))
    if [ "$operator_line_rc" -eq 0 ] && grep -q '^All tests passed\.$' <<< "$operator_line_out"; then
        PASS=$((PASS + 1)); echo "  PASS: operator-line e.line ($tier)"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: operator-line e.line ($tier, rc=$operator_line_rc)"
        printf '%s\n' "$operator_line_out" | eigs_failure_output
    fi

    operator_line_out=$(env "${operator_line_env[@]}" "$EIGS" "$TESTS_DIR/test_operator_line_parent.eigs" </dev/null 2>&1)
    operator_line_rc=$?
    TOTAL=$((TOTAL + 1))
    if [ "$operator_line_rc" -eq 0 ] && grep -q '^All tests passed\.$' <<< "$operator_line_out"; then
        PASS=$((PASS + 1)); echo "  PASS: operator-line parent restoration ($tier)"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: operator-line parent restoration ($tier, rc=$operator_line_rc)"
        printf '%s\n' "$operator_line_out" | eigs_failure_output
    fi

    operator_line_out=$(env "${operator_line_env[@]}" "$EIGS" "$TESTS_DIR/operator_line_module.eigs" </dev/null 2>&1)
    operator_line_rc=$?
    TOTAL=$((TOTAL + 1))
    if [ "$operator_line_rc" -ne 0 ] &&
       grep -Eq '^Error .*operator_line_module\.eigs:8:' <<< "$operator_line_out" &&
       grep -qF '     8 |     r is 1 / (' <<< "$operator_line_out" &&
       grep -qF '       |            ^' <<< "$operator_line_out" &&
       grep -Eq '^  at <module> \(.*operator_line_module\.eigs:8\)$' <<< "$operator_line_out"; then
        PASS=$((PASS + 1)); echo "  PASS: operator-line diagnostic ($tier)"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: operator-line diagnostic ($tier, rc=$operator_line_rc)"
        printf '%s\n' "$operator_line_out" | eigs_failure_output
    fi
done
unset tier operator_line_env operator_line_out operator_line_rc
