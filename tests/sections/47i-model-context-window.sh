echo "[47i] Model inference context window (#1405)"
CW_PROBE_PATH=$(mktemp "${TMPDIR:-/tmp}/eigs_context_probe.XXXXXX")
printf '%s\n' 'print of (eigen_model_loaded of null)' > "$CW_PROBE_PATH"
CW_PROBE_OUT=$(./eigenscript "$CW_PROBE_PATH" 2>&1); CW_PROBE_RC=$?
rm -f "$CW_PROBE_PATH"
if grep -q "undefined variable 'eigen_model_loaded'" <<< "$CW_PROBE_OUT"; then
    section_skip "binary built without EIGENSCRIPT_EXT_MODEL"
else
    TOTAL=$((TOTAL + 1))
    if ! rc_ok "$CW_PROBE_RC" "$CW_PROBE_OUT" || [ "$CW_PROBE_OUT" != 0 ]; then
        FAIL=$((FAIL + 1))
        echo "  FAIL: model capability probe (rc=$CW_PROBE_RC)"
        printf '%s\n' "$CW_PROBE_OUT"
    else
        CW_OUTPUT=$(bash "$TESTS_DIR/test_model_context_window.sh" 2>&1); CW_RC=$?
        if [ "$CW_RC" -eq 0 ] && rc_ok "$CW_RC" "$CW_OUTPUT" &&
            grep -q '^MODEL CONTEXT WINDOW: [1-9][0-9]* passed, 0 failed$' <<< "$CW_OUTPUT"; then
            PASS=$((PASS + 1))
            echo "  PASS: model context boundaries, refusal, and replay alignment"
        else
            FAIL=$((FAIL + 1))
            echo "  FAIL: model context-window checks (rc=$CW_RC)"
        fi
        printf '%s\n' "$CW_OUTPUT"
    fi
fi
echo ""
