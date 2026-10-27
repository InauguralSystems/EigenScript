# [18e] The actual variant path must find the source-tree stdlib. Running this
# from a directory outside the checkout excludes containing-file and project-
# root hits, and using build/<active-variant>/eigenscript (not src/eigenscript)
# exercises the executable path that exposed #1679.
echo "[18e] Variant binary stdlib resolution (#1679)"
VARIANT_STDLIB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/eigs_variant_stdlib.XXXXXX")
cp "$TESTS_DIR/test_variant_stdlib.eigs" "$VARIANT_STDLIB_DIR/probe.eigs"
if [ -n "${EIGS_ACTIVE_VARIANT:-}" ]; then
    VARIANT_STDLIB_BIN="$TESTS_DIR/../build/$EIGS_ACTIVE_VARIANT/eigenscript"
    echo "  active variant: $EIGS_ACTIVE_VARIANT"
    VARIANT_STDLIB_OUTPUT=$($EIGS_TMO "$VARIANT_STDLIB_BIN" \
        "$VARIANT_STDLIB_DIR/probe.eigs" 2>&1)
    VARIANT_STDLIB_RC=$?
else
    VARIANT_STDLIB_BIN=""
    VARIANT_STDLIB_OUTPUT="ERROR: cannot resolve src/eigenscript to an active build/<variant>/eigenscript"
    VARIANT_STDLIB_RC=1
fi
rm -rf "$VARIANT_STDLIB_DIR"
TOTAL=$((TOTAL + 1))
if [ "$VARIANT_STDLIB_RC" -eq 0 ] && rc_ok "$VARIANT_STDLIB_RC" "$VARIANT_STDLIB_OUTPUT" &&
   grep -q '^Tests: 1 | Pass: 1 | Fail: 0$' <<< "$VARIANT_STDLIB_OUTPUT"; then
    PASS=$((PASS + 1))
    echo "  PASS: build/$EIGS_ACTIVE_VARIANT/eigenscript loads the repository stdlib directly"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: variant binary stdlib resolution (rc=$VARIANT_STDLIB_RC)"
fi
printf '%s\n' "$VARIANT_STDLIB_OUTPUT"
unset VARIANT_STDLIB_DIR VARIANT_STDLIB_BIN VARIANT_STDLIB_OUTPUT VARIANT_STDLIB_RC
echo ""
