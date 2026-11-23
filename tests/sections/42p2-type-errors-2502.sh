echo "[42p2] Type errors precede writes; nested scans terminate (#2502)"
for type_mode in unset 0 1; do
    TOTAL=$((TOTAL + 1))
    if [ "$type_mode" = unset ]; then
        type_out=$(env -u EIGS_STRICT ./eigenscript "$TESTS_DIR/type_errors_2502_depth.eigs" 2>&1); type_rc=$?
    else
        type_out=$(EIGS_STRICT="$type_mode" ./eigenscript "$TESTS_DIR/type_errors_2502_depth.eigs" 2>&1); type_rc=$?
    fi
    if rc_ok "$type_rc" "$type_out" && [ "$type_rc" -eq 0 ] &&
       grep -qxF 'DEPTH2502: complete' <<< "$type_out" &&
       grep -qF 'All tests passed' <<< "$type_out"; then
        PASS=$((PASS + 1)); echo "  PASS: cycle and 10000-deep list, EIGS_STRICT=$type_mode"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: nested scan EIGS_STRICT=$type_mode rc=$type_rc"; printf '%s\n' "$type_out"
    fi
done
TOTAL=$((TOTAL + 1))
type_out=$(python3 "$TESTS_DIR/type_errors_2502.py" --binary ./eigenscript --writer all 2>&1); type_rc=$?
printf '%s\n' "$type_out"
if rc_ok "$type_rc" "$type_out" && [ "$type_rc" -eq 0 ] && grep -q '^PASS: writers2502 examined=' <<< "$type_out"; then
    PASS=$((PASS + 1)); echo "  PASS: typed writes preserve every tested target on raise"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: typed writes (rc=$type_rc)"
fi
echo ""
