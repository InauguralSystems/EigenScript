echo "[104e] Integer task handles (#2481)"
check_eigs_suite "first ids, slot reuse, task_self and fractional-id rejection" test_task_ids.eigs "All tests passed"
. "$TESTS_DIR/suite_variant.sh"
variant=$(suite_binary_variant)
if [ -z "$variant" ]; then
    section_skip "task handle C API needs a make-variant binary"
else
    suite_variant_is_asan "$variant" || variant=release
    TOTAL=$((TOTAL + 1))
    task_handles_rc=0
    task_handles_out=$(make -s -C .. TASK_HANDLES_VARIANT="$variant" task-handles-test 2>&1) || task_handles_rc=$?
    if [ "$task_handles_rc" -eq 0 ]; then
        task_handles_out=$(../build/$variant/test_task_handles 2>&1) || task_handles_rc=$?
    fi
    if [ "$task_handles_rc" -eq 0 ] && rc_ok "$task_handles_rc" "$task_handles_out" &&
       grep -qxF 'PASS: integer task handle types, generation boundaries and invalid ids' <<< "$task_handles_out"; then
        PASS=$((PASS + 1))
        echo "  PASS: integer task handle C API"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: integer task handle C API (rc=$task_handles_rc)"
        printf '%s\n' "$task_handles_out"
    fi
fi
echo ""
