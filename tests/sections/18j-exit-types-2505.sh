echo "[18j1] Exit codes reject wrong types before requesting exit (#2505)"
EXIT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/eigs-exit-2505.XXXXXX") || exit 1
EXIT_TABLE='"1"|0|type_mismatch
{"k": 1}|0|type_mismatch
(["a"])|0|type_mismatch
(["a", 3])|0|type_mismatch
true|0|type_mismatch
([true])|0|type_mismatch
(buffer of 1)|0|type_mismatch
((x) => x)|0|type_mismatch
null|0|
[]|0|
([])|0|
5|5|
([3])|3|
2.5|0|value
2147483648|0|value'
EXIT_DECLARED=$(printf '%s\n' "$EXIT_TABLE" | wc -l | tr -d ' ')
for EXIT_MODE in default 0 1; do
    EXIT_EXAMINED=0
    while IFS='|' read -r EXIT_ARG EXIT_WANT EXIT_KIND; do
        EXIT_EXAMINED=$((EXIT_EXAMINED + 1))
        printf 'try:\n    exit of %s\n    print of "returned"\ncatch e:\n    print of e.kind\n    print of (contains of [e.message, "exit"])\nprint of "after catch"\n' "$EXIT_ARG" >"$EXIT_DIR/row.eigs"
        if [ "$EXIT_MODE" = default ]; then
            EXIT_OUT=$(env -u EIGS_STRICT "$EIGS" "$EXIT_DIR/row.eigs" 2>&1); EXIT_RC=$?
        else
            EXIT_OUT=$(EIGS_STRICT=$EXIT_MODE "$EIGS" "$EXIT_DIR/row.eigs" 2>&1); EXIT_RC=$?
        fi
        EXIT_EXPECTED=""
        if [ -n "$EXIT_KIND" ]; then EXIT_EXPECTED=$(printf '%s\ntrue\nafter catch' "$EXIT_KIND"); fi
        TOTAL=$((TOTAL + 1))
        if rc_expect "$EXIT_WANT" "$EXIT_RC" "$EXIT_OUT" && [ "$EXIT_OUT" = "$EXIT_EXPECTED" ]; then
            PASS=$((PASS + 1)); echo "  PASS: exit of $EXIT_ARG strict=$EXIT_MODE rc=$EXIT_RC kind=${EXIT_KIND:-none}"
        else
            FAIL=$((FAIL + 1)); echo "  FAIL: exit of $EXIT_ARG strict=$EXIT_MODE rc=$EXIT_RC expected=$EXIT_WANT kind=${EXIT_KIND:-none}"
            printf '%s\n' "$EXIT_OUT"
        fi
    done <<< "$EXIT_TABLE"
    if [ "$EXIT_EXAMINED" -ne "$EXIT_DECLARED" ] || [ "$EXIT_DECLARED" -le 0 ]; then
        TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); echo "  FAIL: exit examined=$EXIT_EXAMINED declared=$EXIT_DECLARED"
    fi
done
rm -rf "$EXIT_DIR"
unset EXIT_DIR EXIT_TABLE EXIT_DECLARED EXIT_EXAMINED EXIT_MODE EXIT_ARG EXIT_WANT EXIT_KIND EXIT_OUT EXIT_RC EXIT_EXPECTED
