echo "[0fy] Nonfinite text, tape fidelity and JSON overflow (#1758 R2.5)"
EIGS_STRICT=0 check_eigs_suite "nonfinite text and fixed-decimal formatters" test_phase2_nonfinite_text.eigs '^Tests: 24 | Pass: 24 | Fail: 0$'
EIGS_STRICT=1 check_eigs_suite "formatting existing nonfinite values under strict mode" test_phase2_nonfinite_text_strict.eigs '^Tests: 20 | Pass: 20 | Fail: 0$'
TOTAL=$((TOTAL + 1))
IEEE_LINT_OUT=$(bash "$TESTS_DIR/phase2/lint_decode_overflow.sh" "$TESTS_DIR/../src/eigenscript" 2>&1); IEEE_LINT_RC=$?
if rc_ok "$IEEE_LINT_RC" "$IEEE_LINT_OUT" && grep -q '^lint-decode-overflow: cases=12; overflow refuses; finite and malformed controls preserved$' <<< "$IEEE_LINT_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: lint manifest JSON overflow returns failure"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: lint manifest overflow (rc=$IEEE_LINT_RC)"
    printf '%s\n' "$IEEE_LINT_OUT" | eigs_failure_output
fi
IEEE_IO_VARIANT=$("$TESTS_DIR/../tools/active_variant.sh" "$TESTS_DIR/..")
IEEE_IO_VARIANT_RC=$?
case "$IEEE_IO_VARIANT_RC" in
    0) ;;
    1) IEEE_IO_VARIANT=build-sh ;;
    *) IEEE_IO_VARIANT= ;;
esac
if [ "$IEEE_IO_VARIANT" = build-sh ]; then
    section_skip "C IEEE I/O fixtures require a Make variant; hosted matrix covers them"
else
    for IEEE_IO_TEST in nonfinite-tape decoder-overflow; do
        TOTAL=$((TOTAL + 1))
        if [ -z "$IEEE_IO_VARIANT" ]; then
            FAIL=$((FAIL + 1)); echo "  FAIL: IEEE I/O fixture binary variant missing or ambiguous"
        else
            case "$IEEE_IO_TEST" in
                nonfinite-tape)
                    IEEE_IO_OUT=$(make --no-print-directory -C "$TESTS_DIR/.." "IEEE_IO_VARIANT=$IEEE_IO_VARIANT" nonfinite-tape-test 2>&1); IEEE_IO_RC=$?
                    IEEE_IO_WANT='nonfinite-tape: values=10 raw_buffer_cells=14 malformed=19 recordings=2 checks=48 failures=0'
                    ;;
                decoder-overflow)
                    IEEE_IO_OUT=$(make --no-print-directory -C "$TESTS_DIR/.." "IEEE_IO_VARIANT=$IEEE_IO_VARIANT" decoder-overflow-test 2>&1); IEEE_IO_RC=$?
                    IEEE_IO_WANT='decoder-overflow: checks=70 failures=0'
                    ;;
            esac
            IEEE_IO_CLASS=0
            lsan_classify "$IEEE_IO_OUT" || IEEE_IO_CLASS=$?
            if [ "$IEEE_IO_RC" -eq 0 ] && [ "$IEEE_IO_CLASS" -eq 2 ] &&
               ! grep -q 'warning:' <<< "$IEEE_IO_OUT" &&
               grep -Fxq "$IEEE_IO_WANT" <<< "$IEEE_IO_OUT"; then
                PASS=$((PASS + 1)); echo "  PASS: $IEEE_IO_TEST production C regression"
            else
                FAIL=$((FAIL + 1)); echo "  FAIL: $IEEE_IO_TEST (rc=$IEEE_IO_RC, sanitizer-class=$IEEE_IO_CLASS)"
                printf '%s\n' "$IEEE_IO_OUT" | eigs_failure_output
            fi
        fi
    done
fi
IEEE_IO_FLAGS=
if [ -n "$IEEE_IO_VARIANT" ] && [ "$IEEE_IO_VARIANT" != build-sh ]; then
    IEEE_IO_FLAGS=$(make -s --no-print-directory -C "$TESTS_DIR/.." "print-FLAGS_$IEEE_IO_VARIANT")
fi
case "$IEEE_IO_FLAGS" in
*"-DEIGENSCRIPT_EXT_HTTP=1"*)
    TOTAL=$((TOTAL + 1))
    IEEE_HTTP_OUT=$(bash "$TESTS_DIR/phase2/http_decode_overflow.sh" "$TESTS_DIR/../src/eigenscript" 2>&1); IEEE_HTTP_RC=$?
    if rc_ok "$IEEE_HTTP_RC" "$IEEE_HTTP_OUT" && grep -q '^http-decode-overflow:' <<< "$IEEE_HTTP_OUT"; then
        PASS=$((PASS + 1)); echo "  PASS: deterministic HTTP decoder refusal preserves replay ordering"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: HTTP decoder refusal (rc=$IEEE_HTTP_RC)"
        printf '%s\n' "$IEEE_HTTP_OUT" | eigs_failure_output
    fi
    ;;
esac
echo ""
