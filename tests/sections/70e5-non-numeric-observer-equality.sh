# #1992: generated non-numeric corpus gates the equality route for every row.
echo "[70e5] Non-numeric observer equality (#1992)"
TOTAL=$((TOTAL + 1))
NN_OUTPUT=$(python3 "$TESTS_DIR/../tools/observer_oracle/non_numeric.py" "$EIGS" 2>&1); NN_RC=$?
if [ "$NN_RC" -eq 0 ] && \
   grep -q '^corpus rows=52 checkpoints=208 seed=1992$' <<< "$NN_OUTPUT" && \
   grep -q '^verdict=INC matches STD-EQ$' <<< "$NN_OUTPUT"; then
    PASS=$((PASS + 1))
    printf '%s\n' "$NN_OUTPUT"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: non-numeric observer corpus (rc=$NN_RC); output follows"
    printf '%s\n' "$NN_OUTPUT" | sed 's/^/    /'
fi
