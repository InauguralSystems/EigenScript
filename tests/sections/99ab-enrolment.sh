# [99ab] Test enrolment (#1264): a tests/*.sh or tests/*.py that no section,
# workflow step or enrolled script invokes is red, by name. PR #1260's test sat
# unrun until a maintainer noticed. Self-test case count pinned ([99o] lesson).
echo "[99ab] test enrolment (#1264)"
TOTAL=$((TOTAL + 1))
enrol_out=$(bash "$TESTS_DIR/../tools/enrolment_check.sh" 2>&1); enrol_rc=$?
if [ "$enrol_rc" -eq 0 ]; then
    PASS=$((PASS + 1)); echo "  $enrol_out"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: test enrolment (rc=$enrol_rc)"
    printf '%s\n' "$enrol_out" | grep -E 'FAIL|ABORT' | head -8 | sed 's/^/      /'
fi
echo ""
