echo "[47j] Shared by-name binder analysis (#1903, #1904, #1905)"
for binder_tier in interpreter default osr; do
    TOTAL=$((TOTAL + 1))
    case "$binder_tier" in
        interpreter) binder_env=(EIGS_JIT_OFF=1) ;;
        default) binder_env=() ;;
        osr) binder_env=(EIGS_JIT_OSR_THRESHOLD=1) ;;
    esac
    binder_out=$(env "${binder_env[@]}" ./eigenscript "$TESTS_DIR/test_by_name_binders.eigs" 2>&1); binder_rc=$?
    opcode_out=$(env "${binder_env[@]}" EIGS_DUMP_BC=1 ./eigenscript "$TESTS_DIR/test_for_local_write_opcodes.eigs" 2>&1); opcode_rc=$?
    plain_bc=$(awk '/=== .*opcode_slot_plain/{inside=1; next} inside && /^=== /{exit} inside{print}' <<< "$opcode_out")
    nested_bc=$(awk '/=== .*opcode_slot_nested/{inside=1; next} inside && /^=== /{exit} inside{print}' <<< "$opcode_out")
    loop_env_bc=$(awk '/=== .*opcode_loop_environment/{inside=1; next} inside && /^=== /{exit} inside{print}' <<< "$opcode_out")
    if [ "$binder_rc" -eq 0 ] && rc_ok "$binder_rc" "$binder_out" && grep -q 'Fail: 0' <<< "$binder_out" \
            && [ "$opcode_rc" -eq 0 ] && rc_ok "$opcode_rc" "$opcode_out" \
            && grep -q 'SET_LOCAL' <<< "$plain_bc" && ! grep -q 'SET_FN_NAME_LOCAL' <<< "$plain_bc" \
            && grep -q 'SET_LOCAL' <<< "$nested_bc" && ! grep -q 'SET_FN_NAME_LOCAL' <<< "$nested_bc" \
            && grep -q 'SET_FN_NAME_LOCAL' <<< "$loop_env_bc"; then
        PASS=$((PASS + 1)); echo "  PASS: $binder_tier"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: $binder_tier (rc=$binder_rc)"
        printf '%s\n' "$binder_out" | sed 's/^/      /'
        printf '%s\n' "$opcode_out" | sed 's/^/      /'
    fi
done
echo ""
