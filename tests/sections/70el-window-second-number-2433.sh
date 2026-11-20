# #2433: value windows made at the second number; lowered-window tapes and
# one-number programs against outputs taken from the base build.
echo "[70el] Value windows at the second number (#2433)"
TOTAL=$((TOTAL + 1))
WSN_OUT=$(EIGS="$EIGS" bash "$TESTS_DIR/test_window_second_number.sh" 2>&1); WSN_RC=$?
WSN_SUM=$(grep '^window-second-number: ' <<< "$WSN_OUT")
WSN_RE='^window-second-number: tapes=([0-9]+)/([0-9]+) programs=([0-9]+)/([0-9]+) runs=([0-9]+) expectations=[0-9]+ failures=0$'
if [ "$WSN_RC" -eq 0 ] && [[ $WSN_SUM =~ $WSN_RE ]] && [ "${BASH_REMATCH[1]}" -gt 0 ] &&
   [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] && [ "${BASH_REMATCH[3]}" = "${BASH_REMATCH[4]}" ] &&
   [ "$(grep -c '^PASS: ' <<< "$WSN_OUT")" -eq $((BASH_REMATCH[1] + BASH_REMATCH[5])) ] &&
   ! grep -q '^FAIL' <<< "$WSN_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: [70el] $WSN_SUM"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: [70el] window-second-number (rc=$WSN_RC)"
    printf '%s\n' "$WSN_OUT" | sed 's/^/    /'
fi
unset WSN_OUT WSN_RC WSN_SUM WSN_RE
echo ""
