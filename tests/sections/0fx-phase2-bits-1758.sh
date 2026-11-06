echo "[0fx] IEEE bit access and canonical embed doubles (#1758 R2.4)"
EIGS_STRICT=0 check_eigs_suite "bits APIs and N13 controls with strict mode off" test_phase2_bits.eigs '^Tests: 169 | Pass: 169 | Fail: 0$'
EIGS_STRICT=1 check_eigs_suite "bits APIs and N13 controls with strict mode on" test_phase2_bits.eigs '^Tests: 169 | Pass: 169 | Fail: 0$'

BITS_VARIANT=$("$TESTS_DIR/../tools/active_variant.sh" "$TESTS_DIR/..")
BITS_VARIANT_RC=$?
case "$BITS_VARIANT_RC" in
    0) ;;
    1) BITS_VARIANT=build-sh ;;
    *) BITS_VARIANT= ;;
esac

if [ "$BITS_VARIANT" = build-sh ]; then
    section_skip "C embed NaN fixture needs a Make variant; hosted phase2 release/ASan runs it"
else
    TOTAL=$((TOTAL + 1))
    if [ -z "$BITS_VARIANT" ]; then
        FAIL=$((FAIL + 1)); echo "  FAIL: embed NaN fixture binary variant missing or ambiguous"
    else
        BITS_C_OUT=$(make --no-print-directory -C "$TESTS_DIR/.." "EMBED_NAN_VARIANT=$BITS_VARIANT" embed-nan-test 2>&1); BITS_C_RC=$?
        BITS_C_CLASS=0
        lsan_classify "$BITS_C_OUT" || BITS_C_CLASS=$?
        if [ "$BITS_C_RC" -eq 0 ] && [ "$BITS_C_CLASS" -eq 2 ] &&
           ! grep -q 'warning:' <<< "$BITS_C_OUT" &&
           grep -qx 'embed-nan: PASS inputs=20 modes=2 cases=40 callbacks=20 arithmetic=4 constructors=2 checks=1020 failures=0' <<< "$BITS_C_OUT"; then
            PASS=$((PASS + 1)); echo "  PASS: C double boundaries and physical NaN storage are canonical"
        else
            FAIL=$((FAIL + 1)); echo "  FAIL: embed NaN fixture (rc=$BITS_C_RC, sanitizer-class=$BITS_C_CLASS)"
            printf '%s\n' "$BITS_C_OUT" | eigs_failure_output
        fi
    fi
fi
echo ""
