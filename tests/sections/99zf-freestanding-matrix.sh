echo "[99zf] Freestanding compiler/header matrix (#1985)"
TOTAL=$((TOTAL + 1))
FS_MATRIX_OUT=$(bash "$TESTS_DIR/../tools/freestanding_check.sh" 2>&1); FS_MATRIX_RC=$?
FS_MATRIX_ROWS=$(grep -c '^freestanding row:' <<< "$FS_MATRIX_OUT")
FS_MATRIX_STAGE1=$(grep -c '^OK stage 1 \[' <<< "$FS_MATRIX_OUT")
FS_MATRIX_STAGE2=$(grep -c '^OK stage 2 \[' <<< "$FS_MATRIX_OUT")
if [ "$FS_MATRIX_RC" -eq 0 ] && [ "$FS_MATRIX_ROWS" -eq 4 ] && \
   [ "$FS_MATRIX_STAGE1" -eq 4 ] && [ "$FS_MATRIX_STAGE2" -eq 4 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: four freestanding rows passed both symbol stages"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: freestanding matrix (rc=$FS_MATRIX_RC rows=$FS_MATRIX_ROWS stage1=$FS_MATRIX_STAGE1 stage2=$FS_MATRIX_STAGE2)"
    printf '%s\n' "$FS_MATRIX_OUT" | tail -80
fi
unset FS_MATRIX_OUT FS_MATRIX_RC FS_MATRIX_ROWS FS_MATRIX_STAGE1 FS_MATRIX_STAGE2
echo ""
