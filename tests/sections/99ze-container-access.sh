# #1665 arm D: Value LIST/DICT element storage stays behind src/container.h.
echo "[99ze] Container accessor boundary (#1665)"
TOTAL=$((TOTAL + 1))
CA_OUTPUT=$(bash "$TESTS_DIR/../tools/container_access_check.sh" 2>&1); CA_RC=$?
if [ "$CA_RC" -eq 0 ] && \
   grep -qE '^container-access: examined=[1-9][0-9]* allowed=[0-9]+ violations=0$' <<< "$CA_OUTPUT"; then
    PASS=$((PASS + 1))
    printf '%s\n' "$CA_OUTPUT" | grep '^container-access:'
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: container accessor boundary (rc=$CA_RC); output follows"
    printf '%s\n' "$CA_OUTPUT" | sed 's/^/    /'
fi
