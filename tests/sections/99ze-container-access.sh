# #1665 arm D: Value LIST/DICT element storage stays behind src/container.h.
echo "[99ze] Container accessor boundary (#1665)"
TOTAL=$((TOTAL + 1))
CA_OUTPUT=$(bash "$TESTS_DIR/../tools/container_access_check.sh" 2>&1); CA_RC=$?
if [ "$CA_RC" -eq 0 ] && \
   grep -qE '^container-access: examined=[1-9][0-9]* allowed=[0-9]+ violations=0$' <<< "$CA_OUTPUT" && \
   grep -qE '^container-migrated: files=[0-9]+ examined=[0-9]+ violations=0$' <<< "$CA_OUTPUT"; then
    PASS=$((PASS + 1))
    printf '%s\n' "$CA_OUTPUT" | grep '^container-access:'
    printf '%s\n' "$CA_OUTPUT" | grep '^container-migrated:'
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: container accessor boundary (rc=$CA_RC); output follows"
    printf '%s\n' "$CA_OUTPUT" | sed 's/^/    /'
fi

# Planted fault: enrolling a forbidden legacy borrow must turn the gate red.
TOTAL=$((TOTAL + 1))
plant_dir=$(mktemp -d "${TESTS_DIR}/../.container-plant.XXXXXX")
printf 'void plant(void) { list_get_borrow(0, 0); }\n' > "$plant_dir/plant.c"
printf '%s\n' "${plant_dir#"$TESTS_DIR/../"}/plant.c" > "$plant_dir/list.txt"
set +e
PLANT_OUTPUT=$(cd "$TESTS_DIR/.." && EIGS_CONTAINER_EXPECT_VIOLATION=1 EIGS_CONTAINER_MIGRATED_LIST="${plant_dir#"$TESTS_DIR/../"}/list.txt" bash tools/container_access_check.sh 2>&1)
PLANT_RC=$?
set -e
rm -rf "$plant_dir"
if [ "$PLANT_RC" -eq 0 ] && grep -qE '^container-migrated: files=1 examined=1 violations=1$' <<< "$PLANT_OUTPUT" && \
   grep -q '^container-migrated-plant: PASS$' <<< "$PLANT_OUTPUT"; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1)); echo "  FAIL: migrated-access plant rc=$PLANT_RC"; printf '%s\n' "$PLANT_OUTPUT" | tail -20
fi
