# [137b] #2320: section [137] runs ONCE per CI run. linux / gcc owns it; every
# other Linux lane defers it through tests/gfx137_defer_allowlist.txt, and on a
# PR the owner runs it only when the diff touches a [137] input. The tree check
# reads ci.yml and fails on zero or two queue runners, a native lane that
# defers, an unlisted or stale deferral id, a scope that fails open, and a
# missing owner receipt; it executes the runner's real [137] block against a
# stub corpus. Its selftest (17 planted faults, each of which must turn its
# check red) is the tools/selftests.txt row, run by the gate self-tests job.
# The check never skips: a missing python3 or PyYAML is an instrument error,
# and that is a FAIL here.
echo "[137b] gfx ASan corpus runs once per CI run: owner, allowlisted deferrals, PR scope (#2320)"
G137_OUT=$(bash "$TESTS_DIR/test_gfx137_once_2320.sh" 2>&1); G137_RC=$?
TOTAL=$((TOTAL + 1))
if [ "$G137_RC" -eq 0 ] && grep -qx 'PLAN: 11' <<< "$G137_OUT" \
   && [ "$(grep -c '^  PASS: C' <<< "$G137_OUT")" -eq 11 ] && ! grep -q '^  FAIL:' <<< "$G137_OUT"; then
    PASS=$((PASS + 1))
    echo "  PASS: the tree holds all 11 [137]-once checks"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: [137]-once tree check (rc=$G137_RC)"
    printf '%s\n' "$G137_OUT" | sed 's/^/    /'
fi
echo ""
