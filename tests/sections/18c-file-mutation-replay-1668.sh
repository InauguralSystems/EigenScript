echo "[18c] File mutation results replay from the tape when the live outcome changes (#1668, #1885)"
FMR_OUTPUT=$(bash "$TESTS_DIR/test_file_mutation_replay.sh" 2>&1); FMR_RC=$?
TOTAL=$((TOTAL + 1))
if [ "$FMR_RC" -eq 0 ] && rc_ok "$FMR_RC" "$FMR_OUTPUT" &&
   grep -qxF 'FILE MUTATION REPLAY: PASS (byte-identical after every live outcome changed)' <<< "$FMR_OUTPUT"; then
    PASS=$((PASS + 1)); echo "  PASS: write/rename/remove results replay from the tape after every live outcome changed"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: file mutation replay (rc=$FMR_RC)"
fi
printf '%s\n' "$FMR_OUTPUT"
unset FMR_OUTPUT FMR_RC
echo ""
