echo "[z9x2] Executed builtin error tables (#2550)"
ERROR_TABLE_DOC_OUT=$(python3 "$TESTS_DIR/../tools/builtin_error_table.py" --check 2>&1)
ERROR_TABLE_DOC_RC=$?
printf '%s\n' "$ERROR_TABLE_DOC_OUT"
ERROR_TABLE_OUT=$(python3 "$TESTS_DIR/../tools/builtin_error_table.py" --binary "$EIGS" 2>&1)
ERROR_TABLE_RC=$?
printf '%s\n' "$ERROR_TABLE_OUT"
ERROR_TABLE_EXAMINED=0
for ERROR_TABLE_BUILTIN in tensor_load sgd_update audio_music_play; do
    TOTAL=$((TOTAL + 1))
    ERROR_TABLE_MATCHES=$(grep -Ec "^builtin-error-table: $ERROR_TABLE_BUILTIN [1-9][0-9]* lines x 3 states, 0 failed$" <<< "$ERROR_TABLE_OUT")
    if rc_ok "$ERROR_TABLE_DOC_RC" "$ERROR_TABLE_DOC_OUT" && rc_ok "$ERROR_TABLE_RC" "$ERROR_TABLE_OUT" && [ "$ERROR_TABLE_MATCHES" -eq 1 ]; then
        PASS=$((PASS + 1))
        echo "  PASS: $ERROR_TABLE_BUILTIN error table, complete population in three states"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $ERROR_TABLE_BUILTIN error table child or population"
    fi
    ERROR_TABLE_EXAMINED=$((ERROR_TABLE_EXAMINED + 1))
done
if [ "$ERROR_TABLE_EXAMINED" -ne 3 ]; then
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    echo "  FAIL: error table builtin enumeration"
fi
echo ""
