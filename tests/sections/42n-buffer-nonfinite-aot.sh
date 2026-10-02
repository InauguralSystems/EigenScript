# The existing mirror reports unavailable ouroboros explicitly; a skip is no PASS.
echo "[42n] Optional opt-out boxed-accessor VM/AOT mirror (#1417)"
NF_AOT_OUTPUT=$(EIGS="$PWD/eigenscript" bash "$TESTS_DIR/test_buffer_nonfinite_read_aot.sh" 2>&1); NF_AOT_RC=$?
if [ "$NF_AOT_RC" -eq 0 ] && [[ "$NF_AOT_OUTPUT" == "SKIP: ouroboros AOT checkout not found at "* ]]; then
    section_skip "$NF_AOT_OUTPUT"
else
    TOTAL=$((TOTAL + 1))
    if rc_ok "$NF_AOT_RC" "$NF_AOT_OUTPUT" && grep -q '^PASS: #1417 optional opt-out boxed-accessor VM/AOT mirror matches$' <<< "$NF_AOT_OUTPUT"; then
        PASS=$((PASS + 1))
        echo "  PASS: optional opt-out boxed-accessor VM/AOT mirror"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: optional opt-out boxed-accessor VM/AOT mirror (rc=$NF_AOT_RC)"
        printf '%s\n' "$NF_AOT_OUTPUT"
    fi
fi
echo ""
