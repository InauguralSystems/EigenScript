echo "[2194] bare while parse hint (#2194)"

# A bare Python/JS `while cond:` gets ONE parse error at the `while` token
# naming `loop while`, in the run diagnostic and in --lint --json, with no
# "unexpected indent" cascade from its body. `loop while` and `while` as a
# dict key still parse. Every run must exit with its exact status (1 for a
# parse error, 0 for the program) and carry no sanitizer report: a crash or a
# leak after the right diagnostic is a failure, not a pass.

bare_while_case() {
    TOTAL=$((TOTAL + 1))
    if [ "$1" -eq 1 ]; then
        PASS=$((PASS + 1)); echo "  PASS: $2"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: $2"
        printf '%s\n' "$3" | sed 's/^/    /'
    fi
}

BARE_WHILE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/eigs-bare-while-XXXXXX") || {
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); echo "  FAIL: bare while (mktemp)"
    BARE_WHILE_DIR=
}
if [ -n "$BARE_WHILE_DIR" ]; then
    printf 'i is 0\nwhile i < 3:\n    i is i + 1\n' >"$BARE_WHILE_DIR/bare.eigs"
    printf 'i is 0\nloop while i < 3:\n    i is i + 1\nprint of i\nd is {"while": 7}\nprint of d.while\nd.while is 8\nprint of d.while\n' \
        >"$BARE_WHILE_DIR/ok.eigs"

    BW_OUT=$("$EIGS" "$BARE_WHILE_DIR/bare.eigs" 2>&1); BW_RC=$?
    BW_ERRS=$(printf '%s\n' "$BW_OUT" | grep -c '^Parse error')
    BW_OK=0
    if [ "$BW_RC" -eq 1 ] && [ "$BW_ERRS" -eq 1 ] &&
       [ "$(lsan_classify_name "$BW_OUT")" = none ] &&
       printf '%s\n' "$BW_OUT" | grep -q "^Parse error line 2:1: .*'loop while cond:'" &&
       ! printf '%s\n' "$BW_OUT" | grep -q 'indent'; then
        BW_OK=1
    fi
    bare_while_case "$BW_OK" "bare while: one parse error at 2:1 naming loop while (rc=$BW_RC, errors=$BW_ERRS)" "$BW_OUT"

    BW_JSON=$("$EIGS" --lint --json "$BARE_WHILE_DIR/bare.eigs" 2>"$BARE_WHILE_DIR/lint.err"); BW_JRC=$?
    BW_JERR=$(cat "$BARE_WHILE_DIR/lint.err")
    BW_CODES=$(printf '%s\n' "$BW_JSON" | grep -o '"code":"[A-Z0-9]*"' | wc -l | tr -d ' ')
    BW_OK=0
    if [ "$BW_JRC" -eq 1 ] && [ "$BW_CODES" -eq 1 ] &&
       [ "$(lsan_classify_name "$(printf '%s\n%s' "$BW_JSON" "$BW_JERR")")" = none ] &&
       printf '%s\n' "$BW_JSON" | grep -qF '"code":"E002"' &&
       printf '%s\n' "$BW_JSON" | grep -qF '"line":2,"column":1' &&
       printf '%s\n' "$BW_JSON" | grep -qF "loops are written 'loop while cond:'"; then
        BW_OK=1
    fi
    bare_while_case "$BW_OK" "bare while: --lint --json reports one E002 with the hint (rc=$BW_JRC, diagnostics=$BW_CODES)" "$BW_JSON
$BW_JERR"

    BW_RUN=$("$EIGS" "$BARE_WHILE_DIR/ok.eigs" 2>&1); BW_RRC=$?
    BW_OK=0
    if [ "$BW_RRC" -eq 0 ] && [ "$(lsan_classify_name "$BW_RUN")" = none ] &&
       [ "$BW_RUN" = "$(printf '3\n7\n8')" ]; then
        BW_OK=1
    fi
    bare_while_case "$BW_OK" "loop while and d.while still parse and run (rc=$BW_RRC)" "$BW_RUN"

    rm -rf "$BARE_WHILE_DIR"
fi
