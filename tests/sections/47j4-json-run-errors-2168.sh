echo "[47j4] Ordinary-run JSON errors (#2168)"
TOTAL=$((TOTAL + 1))
json_error_out=$(bash "$TESTS_DIR/test_json_run_errors.sh" 2>&1); json_error_rc=$?
printf '%s\n' "$json_error_out"
if [ "$json_error_rc" -eq 0 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
echo ""
