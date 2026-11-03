echo "[0fw] Non-finite encoder failure and persistence refusal (#1758 R23-1)"
WRITER_VARIANT=$("$TESTS_DIR/../tools/active_variant.sh" "$TESTS_DIR/..")
WRITER_VARIANT_RC=$?
case "$WRITER_VARIANT_RC" in
    0) ;;
    1) WRITER_VARIANT=build-sh ;;
    *) WRITER_VARIANT= ;;
esac
TOTAL=$((TOTAL + 1))
if [ -z "$WRITER_VARIANT" ]; then
    FAIL=$((FAIL + 1)); echo "  FAIL: writer fixture binary variant missing or ambiguous"
else
    WRITER_OUT=$(bash "$TESTS_DIR/phase2/writers.sh" "$WRITER_VARIANT" "$EIGS" 2>&1); WRITER_RC=$?
    WRITER_C_CHECKS=78
    [ "$WRITER_VARIANT" != build-sh ] || WRITER_C_CHECKS=not-run
    if rc_ok "$WRITER_RC" "$WRITER_OUT" && grep -qx "writers: PASS variant=$WRITER_VARIANT c=$WRITER_C_CHECKS store=77 legacy=10 shared=" <<< "$WRITER_OUT"; then
        PASS=$((PASS + 1)); echo "  PASS: store no-mutation and historical sentinel reads; C proof where make variant is available"
        if [ "$WRITER_VARIANT" = build-sh ]; then
            echo "  NOTE: C failure-return fixture belongs to hosted phase2 release/ASan for this build.sh lane"
        fi
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: non-finite writer regression (rc=$WRITER_RC)"
        printf '%s\n' "$WRITER_OUT" | eigs_failure_output
    fi
fi
echo ""
