echo "[47j] Shared by-name binder analysis (#1903, #1904, #1905)"
for binder_tier in interpreter default osr; do
    TOTAL=$((TOTAL + 1))
    case "$binder_tier" in
        interpreter) binder_env=(EIGS_JIT_OFF=1) ;;
        default) binder_env=() ;;
        osr) binder_env=(EIGS_JIT_OSR_THRESHOLD=1) ;;
    esac
    binder_out=$(env "${binder_env[@]}" EIGS_DUMP_BC=1 ./eigenscript "$TESTS_DIR/test_by_name_binders.eigs" 2>&1); binder_rc=$?
    integrity_bc=$(awk '/=== .*for_local_parameter_integrity/{inside=1; next} inside && /^=== /{exit} inside{print}' <<< "$binder_out")
    if [ "$binder_rc" -eq 0 ] && rc_ok "$binder_rc" "$binder_out" && grep -q 'Fail: 0' <<< "$binder_out" \
            && grep -q 'SET_LOCAL' <<< "$integrity_bc" \
            && ! grep -q 'SET_FN_NAME_LOCAL' <<< "$integrity_bc"; then
        PASS=$((PASS + 1)); echo "  PASS: $binder_tier"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: $binder_tier (rc=$binder_rc)"
        printf '%s\n' "$binder_out" | sed 's/^/      /'
    fi
done
echo ""
