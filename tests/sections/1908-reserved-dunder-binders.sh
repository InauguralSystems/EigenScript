echo "[1908] Reserved dunder binders (#1908)"

DU_DIR=$(mktemp -d "${TMPDIR:-/tmp}/eigs_dunder.XXXXXX")
dunder_refuse() {
    DU_LABEL=$1; DU_SOURCE=$2
    printf '%b\n' "$DU_SOURCE" > "$DU_DIR/case.eigs"
    DU_OUT=$($EIGS_TMO ./eigenscript "$DU_DIR/case.eigs" </dev/null 2>&1); DU_RC=$?
    TOTAL=$((TOTAL + 1))
    if [ "$DU_RC" != 0 ] && grep -q "reserved for the runtime" <<< "$DU_OUT" && grep -q '\[E006\]' <<< "$DU_OUT"; then
        PASS=$((PASS + 1)); echo "  PASS: $DU_LABEL"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL: $DU_LABEL (rc=$DU_RC)"; printf '%s\n' "$DU_OUT" | eigs_failure_output
    fi
}

# Every source-token binder constructed by parser.c. Dot/index targets only
# mutate an object and are not name binders; match cases are expressions.
dunder_refuse "plain assignment" '__assign__ is 1'
dunder_refuse "compound assignment" '__compound__ += 1'
dunder_refuse "local assignment" 'local __local__ is 1'
dunder_refuse "define name" 'define __function__() as:\n    return 1'
dunder_refuse "define parameter" 'define f(__parameter__) as:\n    return 1'
dunder_refuse "lambda parameter" 'f is (__lambda__) => __lambda__'
dunder_refuse "for binder" 'for __item__ in [1]:\n    print of __item__'
dunder_refuse "comprehension binder" 'x is [n for __item__ in [1]]'
dunder_refuse "catch binder" 'try:\n    throw of "x"\ncatch __error__:\n    print of 1'
dunder_refuse "import binder" 'import __module__'
dunder_refuse "destructuring binder" '[ok, __part__] is [1, 2]'
dunder_refuse "eval entry point" 'eval of "__eval__ is 1"'
printf '%s\n' '__loaded__ is 1' > "$DU_DIR/loaded.eigs"
dunder_refuse "load_file entry point" "load_file of \"$DU_DIR/loaded.eigs\""

DU_OUT=$(printf '%s\n' '__repl__ is 1' | $EIGS_TMO ./eigenscript 2>&1); DU_RC=$?
TOTAL=$((TOTAL + 1))
if grep -q '\[E006\]' <<< "$DU_OUT" && grep -q 'reserved for the runtime' <<< "$DU_OUT"; then
    PASS=$((PASS + 1)); echo "  PASS: REPL entry point"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: REPL entry point (rc=$DU_RC)"; printf '%s\n' "$DU_OUT" | eigs_failure_output
fi

printf '%s\n' 'i is 0' 'loop while i < 2:' '    i is i + 1' 'print of __loop_iterations__' > "$DU_DIR/read.eigs"
DU_OUT=$($EIGS_TMO ./eigenscript "$DU_DIR/read.eigs" </dev/null 2>&1); DU_RC=$?
TOTAL=$((TOTAL + 1))
if [ "$DU_RC" = 0 ] && [ "$DU_OUT" = 2 ]; then
    PASS=$((PASS + 1)); echo "  PASS: loop while synthesizes a legally readable runtime binding"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: runtime dunder read (rc=$DU_RC out='$DU_OUT')"
fi

rm -rf "$DU_DIR"
unset DU_DIR DU_LABEL DU_SOURCE DU_OUT DU_RC
check_eigs_suite "meta-interpreter refuses a dunder binder" test_meta_reserved_dunder.eigs "All tests passed"
