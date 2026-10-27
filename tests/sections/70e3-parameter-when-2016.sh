echo "[70e3] Parameter assignment count and tape relation (#2016)"
PW_EXPECTED='[1, 2, 3, 13, 3]'
for tier in "EIGS_JIT_OFF=1" "" "EIGS_JIT_OSR_THRESHOLD=1"; do
    PW_OUTPUT=$(env $tier ./eigenscript ../tests/test_parameter_when_2016.eigs 2>&1)
    PW_RC=$?
    TOTAL=$((TOTAL + 1))
    if rc_ok "$PW_RC" "$PW_OUTPUT" && [ "$PW_OUTPUT" = "$PW_EXPECTED" ]; then
        PASS=$((PASS + 1)); echo "  PASS: ${tier:-default}: parameter/local counts"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: ${tier:-default}: parameter/local counts (rc=$PW_RC)"
        printf '%s\n' "$PW_OUTPUT" | eigs_failure_output
    fi
done

PW_TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs-when-2016-XXXXXX")
PW_TAPE="$PW_TMP/run.tape"
PW_REC="$PW_TMP/recorded.out"
PW_REP="$PW_TMP/replayed.out"
EIGS_TRACE="$PW_TAPE" EIGS_JIT_OFF=1 ./eigenscript ../tests/test_parameter_when_2016.eigs >"$PW_REC" 2>&1
PW_RC=$?
TOTAL=$((TOTAL + 1))
# Parameter creation is deliberately absent from the tape. Thus each unique
# parameter has `when = 1 + A`, while the local has `when = A`.
PW_COUNTS=$(awk '
    $1 == "A" && $3 ~ /^p_once=/  { once++ }
    $1 == "A" && $3 ~ /^p_twice=/ { twice++ }
    $1 == "A" && $3 ~ /^p_loop=/  { looped++ }
    $1 == "A" && $3 ~ /^q_local=/ { local++ }
    END { print once+0, twice+0, looped+0, local+0 }
' "$PW_TAPE")
if [ "$PW_RC" -eq 0 ] && [ "$PW_COUNTS" = "1 2 12 3" ] &&
   [ "$(cat "$PW_REC")" = "$PW_EXPECTED" ]; then
    PASS=$((PASS + 1)); echo "  PASS: tape A records satisfy parameter offset and local equality"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: tape relation (rc=$PW_RC counts='$PW_COUNTS')"
fi

EIGS_REPLAY="$PW_TAPE" EIGS_JIT_OFF=1 ./eigenscript ../tests/test_parameter_when_2016.eigs >"$PW_REP" 2>&1
PW_RC=$?
TOTAL=$((TOTAL + 1))
if [ "$PW_RC" -eq 0 ] && cmp -s "$PW_REC" "$PW_REP"; then
    PASS=$((PASS + 1)); echo "  PASS: recorded and replayed when answers agree"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: recorded/replayed when answers differ (rc=$PW_RC)"
    diff -u "$PW_REC" "$PW_REP" || true
fi
rm -rf "$PW_TMP"
unset PW_EXPECTED PW_OUTPUT PW_RC PW_TMP PW_TAPE PW_REC PW_REP PW_COUNTS
echo ""
