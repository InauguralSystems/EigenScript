# #1422: the dev-image command audit reports a nonempty step population.
# Keep the original [99zd] YAML/name/stderr witness in the main runner.
echo "[99zdc] Dev-image workflow command availability (#1422)"
TOTAL=$((TOTAL + 1))
CONTAINER_OUTPUT=$(bash "$TESTS_DIR/../tools/workflow_yaml_check.sh" 2>&1); CONTAINER_RC=$?
if [ "$CONTAINER_RC" -eq 0 ] && \
   grep -qE '^workflow-container: OK \(run-steps=[1-9][0-9]*, image=dev-image\)$' <<< "$CONTAINER_OUTPUT"; then
    PASS=$((PASS + 1))
    printf '%s\n' "$CONTAINER_OUTPUT" | grep '^workflow-container: OK'
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: dev-image workflow commands (rc=$CONTAINER_RC); output follows"
    print_captured "dev-image commands, VERBATIM" "$CONTAINER_OUTPUT"
fi
echo ""
