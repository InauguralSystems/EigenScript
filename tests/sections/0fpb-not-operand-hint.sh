echo "[0fpb] not operand parse hint (#1648)"

NOT_HINT='`not` binds below comparisons and `of`; parenthesize it: (not x)'

check_not_hint() {
    TOTAL=$((TOTAL + 1))
    NOT_HINT_SOURCE=$1
    NOT_HINT_NAME=$2
    NOT_HINT_FILE=$(mktemp "${TMPDIR:-/tmp}/eigs-not-hint-XXXXXX.eigs") || {
        FAIL=$((FAIL + 1)); echo "  FAIL: $NOT_HINT_NAME (mktemp)"; return
    }
    printf '%s\n' "$NOT_HINT_SOURCE" >"$NOT_HINT_FILE"
    NOT_HINT_OUTPUT=$("$EIGS" "$NOT_HINT_FILE" 2>&1)
    NOT_HINT_RC=$?
    rm -f "$NOT_HINT_FILE"
    if [ "$NOT_HINT_RC" -ne 0 ] && printf '%s\n' "$NOT_HINT_OUTPUT" | grep -F "$NOT_HINT" >/dev/null; then
        PASS=$((PASS + 1)); echo "  PASS: $NOT_HINT_NAME"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: $NOT_HINT_NAME (rc=$NOT_HINT_RC)"
        printf '%s\n' "$NOT_HINT_OUTPUT"
    fi
}

check_not_hint 'print of not true' 'of operand explains parenthesized not'
check_not_hint '1 == not true' 'comparison operand explains parenthesized not'
