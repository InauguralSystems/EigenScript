echo "[z9x1] Silent builtin errors (#2518/#2521/#2522/#2523)"
CLUSTER_OUT=$(python3 "$TESTS_DIR/test_2521_cluster.py" "$EIGS" 2>&1)
CLUSTER_RC=$?
printf '%s\n' "$CLUSTER_OUT"
CLUSTER_PASS=$(grep -c '^PASS:' <<< "$CLUSTER_OUT")
CLUSTER_FAIL=$(grep -c '^FAIL:' <<< "$CLUSTER_OUT")
CLUSTER_SKIP=$(grep -c '^SKIP:' <<< "$CLUSTER_OUT")
TOTAL=$((TOTAL + CLUSTER_PASS + CLUSTER_FAIL))
PASS=$((PASS + CLUSTER_PASS))
FAIL=$((FAIL + CLUSTER_FAIL))
SKIPPED=$((SKIPPED + CLUSTER_SKIP))
if ! rc_ok "$CLUSTER_RC" "$CLUSTER_OUT" || [ "$CLUSTER_PASS" -eq 0 ]; then
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    echo "  FAIL: cluster child exit or empty population"
fi
echo ""
