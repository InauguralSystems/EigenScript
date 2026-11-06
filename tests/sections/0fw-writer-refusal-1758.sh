echo "[0fw] Non-finite encoder failure and persistence refusal (#1758 R23-1)"
WRITER_VARIANT=$("$TESTS_DIR/../tools/active_variant.sh" "$TESTS_DIR/..")
WRITER_VARIANT_RC=$?
case "$WRITER_VARIANT_RC" in
    0) ;;
    1) WRITER_VARIANT=build-sh ;;
    *) WRITER_VARIANT= ;;
esac

# The C proof uses the actual Make variant's runtime objects. build.sh lanes
# still run both program proofs below; hosted phase2 supplies release/ASan C78.
if [ "$WRITER_VARIANT" = build-sh ]; then
    section_skip "C encoder failure-return fixture needs a Make variant; hosted phase2 release/ASan runs it"
else
    TOTAL=$((TOTAL + 1))
    if [ -z "$WRITER_VARIANT" ]; then
        FAIL=$((FAIL + 1)); echo "  FAIL: writer fixture binary variant missing or ambiguous"
    else
        WRITER_C_OUT=$({ make --no-print-directory -C "$TESTS_DIR/.." "WRITER_JSON_VARIANT=$WRITER_VARIANT" writer-json-test && $EIGS_TMO "$TESTS_DIR/../build/$WRITER_VARIANT/test_writer_json"; } 2>&1); WRITER_C_RC=$?
        WRITER_C_CLASS=0
        lsan_classify "$WRITER_C_OUT" || WRITER_C_CLASS=$?
        if [ "$WRITER_C_RC" -eq 0 ] && [ "$WRITER_C_CLASS" -eq 2 ] &&
           ! grep -q 'warning:' <<< "$WRITER_C_OUT" &&
           grep -qx 'writer-json: refused=15 finite=5 checks=78 failures=0' <<< "$WRITER_C_OUT"; then
            PASS=$((PASS + 1)); echo "  PASS: C encoder returns failure for non-finite payloads without losing ownership"
        else
            FAIL=$((FAIL + 1)); echo "  FAIL: C encoder failure-return fixture (rc=$WRITER_C_RC, sanitizer-class=$WRITER_C_CLASS)"
            printf '%s\n' "$WRITER_C_OUT" | eigs_failure_output
        fi
    fi
fi

# Explicit calls through the ordinary suite runner are the invocation edges.
# Each program owns its assertions; the suite keeps its rc/sanitizer/timeout
# checks and requires the complete expected test-summary line.
WRITER_TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs-writer-suite.XXXXXX"); WRITER_TMP_RC=$?
if [ "$WRITER_TMP_RC" -ne 0 ] || [ -z "$WRITER_TMP" ]; then
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    echo "  FAIL: writer program fixture scratch setup (rc=$WRITER_TMP_RC)"
else
    if mkdir "$WRITER_TMP/store" "$WRITER_TMP/legacy" &&
       cp "$TESTS_DIR/phase2/fixtures/r23-legacy-buffer-nan.db" "$TESTS_DIR/phase2/fixtures/r23-legacy-buffer-infinity.db" "$WRITER_TMP/legacy/"; then
        EIGS_STRICT=0 EIGS_PROBE_TMP="$WRITER_TMP/store" check_eigs_suite \
            "store refusal precedes catalog, ID, record and file mutation" \
            "$TESTS_DIR/phase2/writers/store_refusal.eigs" '^Tests: 77 | Pass: 77 | Fail: 0$'
        EIGS_STRICT=0 EIGS_PROBE_TMP="$WRITER_TMP/legacy" check_eigs_suite \
            "historical non-finite store sentinels remain readable" \
            "$TESTS_DIR/phase2/writers/legacy_nonfinite.eigs" '^Tests: 10 | Pass: 10 | Fail: 0$'
    else
        TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
        echo "  FAIL: writer program fixture directories or legacy data copy"
    fi
    if ! rm -rf "$WRITER_TMP"; then
        TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
        echo "  FAIL: writer program fixture scratch cleanup"
    fi
fi
echo ""
