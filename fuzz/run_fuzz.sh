#!/bin/bash
# EigenScript fuzz smoke: edge cases, adversarial inputs and the curated corpus,
# each run once through the libFuzzer target's per-input body under ASan+UBSan
# (fuzz/fuzz_stdin, built by `make fuzz`). Leak detection is on (#1734): an
# input FAILS on any AddressSanitizer, LeakSanitizer, or UBSan report, or on an
# exit other than 0/1.
#
#   bash fuzz/run_fuzz.sh               the smoke
#   bash fuzz/run_fuzz.sh --plant-leak  only the planted leak (#1734): one input
#                                       that really leaks, which MUST fail
#   bash fuzz/run_fuzz.sh --plant-ubsan only the planted UB (#2097): one input
#                                      that overflows, which MUST fail

case "${1:-}" in
    ""|--plant-leak|--plant-ubsan) ;;
    *) echo "usage: bash fuzz/run_fuzz.sh [--plant-leak|--plant-ubsan]"; exit 2 ;;
esac

cd "$(dirname "$0")/.." || exit 1

FUZZ=./fuzz/fuzz_stdin
if [ ! -x "$FUZZ" ]; then
    echo "Build first: make fuzz"
    exit 1
fi

# One classifier for "is this a sanitizer report, and only a leak?", shared
# with the suite. Without it no report would be read and every input would pass.
if ! { . tests/lsan_classify.sh && declare -F lsan_classify >/dev/null; }; then
    echo "FAIL: tests/lsan_classify.sh did not load, so no report could be read"
    exit 1
fi

# The harness's stderr is the fuzzed program's, so ASan writes its report to
# its own file (log_path), read back per input. Appended last, so a caller's
# ASAN_OPTIONS cannot turn leak detection off.
WORK=$(mktemp -d /tmp/fuzz_XXXXXX) || exit 1
trap 'rm -rf "$WORK"' EXIT
export ASAN_OPTIONS="${ASAN_OPTIONS:+$ASAN_OPTIONS:}detect_leaks=1:log_path=$WORK/asan"
# GCC's UBSan is a separate runtime and does not honor ASan's log_path. Its
# recoverable diagnostics go to stderr, captured per input below and fed to
# the existing classifier together with ASan's log; one policy decides both.

PASS=0
FAIL=0

# One input, one process. A failing input prints what the sanitizer said.
run_case() {
    local name="$1" rc report
    shift
    rm -f "$WORK"/asan.*
    : > "$WORK/ubsan.stderr"
    if [ "$#" -eq 1 ]; then
        timeout 30 "$FUZZ" < "$1" >/dev/null 2>"$WORK/ubsan.stderr"
    else
        timeout 30 "$FUZZ" "$@" >/dev/null 2>"$WORK/ubsan.stderr"
    fi
    rc=$?
    report=$(cat "$WORK"/asan.* "$WORK/ubsan.stderr" 2>/dev/null)
    lsan_classify "$report"
    case $? in
        0) echo "  FAIL: $name (LeakSanitizer)" ;;
        1) echo "  FAIL: $name (sanitizer report)" ;;
        *) if [ $rc -eq 0 ] || [ $rc -eq 1 ]; then
               PASS=$((PASS + 1))
               return 0
           fi
           echo "  FAIL: $name (exit $rc)" ;;
    esac
    FAIL=$((FAIL + 1))
    if [ -n "$report" ]; then
        printf '%s\n' "$report" | awk 'NR <= 150 || /SUMMARY: /' | sed 's/^/    /'
    fi
}

fuzz_test() {
    printf '%s\n' "$2" > "$WORK/input.eigs"
    run_case "$1" "$WORK/input.eigs"
}

# Like fuzz_test but feeds the input with NO trailing newline — for cases where
# the last byte matters (e.g. #304: a backslash at true end-of-source).
fuzz_test_raw() {
    printf '%s' "$2" > "$WORK/input.eigs"
    run_case "$1" "$WORK/input.eigs"
}

# The verdict line, and the exit status: 1 when any input failed.
finish() {
    echo ""
    echo "============================================"
    echo "  FUZZ: $PASS passed, $FAIL failed"
    echo "============================================"
    [ "$FAIL" -eq 0 ] || exit 1
    exit 0
}

if [ "${1:-}" = --plant-leak ]; then
    # The harness binds fuzz_leak_plant only under this switch. It allocates a
    # dict and drops it, so the one input below must fail as a leak, through
    # the same run_case as every other input. CI also checks the report names
    # make_dict called from fuzz_leak_plant.
    export EIGS_FUZZ_LEAK_PLANT=1
    echo "Plant:"
    fuzz_test "plant: orphaned make_dict" 'fuzz_leak_plant of null'
    finish
fi
if [ "${1:-}" = --plant-ubsan ]; then
    # A recoverable signed overflow must still fail through the same report
    # read-back and classifier as every ordinary fuzz input.
    export EIGS_FUZZ_UBSAN_PLANT=1
    echo "Plant:"
    fuzz_test "plant: signed integer overflow" 'fuzz_ubsan_plant of null'
    finish
fi
# A switch inherited from the caller must not bind the plant in the smoke.
unset EIGS_FUZZ_LEAK_PLANT
unset EIGS_FUZZ_UBSAN_PLANT

echo "=== EigenScript Fuzz Tests ==="
echo ""

echo "Edge cases:"
fuzz_test "division by zero" 'x is 1 / 0'
fuzz_test "index out of bounds" 'x is [1,2,3][999]'
fuzz_test "type error" 'x is "a" - 5'
fuzz_test "undefined variable" 'x is nonexistent'
fuzz_test "deep parens" "$(python3 -c "print('x is ' + '(' * 200 + '1' + ')' * 200)")"
fuzz_test "nested lists" "$(python3 -c "print('x is ' + '[' * 50 + '1' + ']' * 50)")"
fuzz_test "empty string" ''
fuzz_test "just braces" '{}'
fuzz_test "unmatched open" '['
fuzz_test "unmatched close" ']'
fuzz_test "bare keywords" 'define'
fuzz_test "bare if" 'if'
fuzz_test "bare match" 'match'
fuzz_test "bare try" 'try:'
fuzz_test "bad chars" 'x is @#$%^&'
fuzz_test "null bytes" 'x is "\x00\x01"'
fuzz_test "break outside loop" 'break'
fuzz_test "continue outside loop" 'continue'
fuzz_test "return at top level" 'return 42'
fuzz_test "huge number" 'x is 999999999999999999999999999999999.999'
fuzz_test "missing module" 'import nonexistent_module'
fuzz_test "pipe to non-fn" '1 |> 2 |> 3'
fuzz_test "for on non-list" 'for i in 99:\n    print of i'
fuzz_test "bad quotes" '""""""""""'
fuzz_test "unclosed f-string" 'f"{{{{{{{"'
# #304: backslash at true end-of-source (no trailing newline) — over-read past
# the NUL terminator. Must be refused as an unterminated string, not read past
# the end. fuzz_test_raw keeps the backslash as the final byte.
fuzz_test_raw "string backslash at EOF" '"\'
fuzz_test_raw "f-string backslash at EOF" 'f"\'

echo ""
echo "Adversarial:"
printf '%s\n' '1' > "$WORK/first.eigs"
run_case "cycle collection survives process reuse (#2094)" \
    "$WORK/first.eigs" fuzz/corpus/lambda.eigs
printf '%s\n' 'len is [1]' > "$WORK/rebind.eigs"
printf '%s\n' 'print of (len of [1, 2])' > "$WORK/use-len.eigs"
alone=$($FUZZ "$WORK/use-len.eigs" 2>"$WORK/rebind-alone.stderr")
sequential=$($FUZZ "$WORK/rebind.eigs" "$WORK/use-len.eigs" 2>"$WORK/rebind-sequential.stderr")
if [ "$alone" = 2 ] && [ "$sequential" = 2 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: a root-name rebind does not contaminate the next input (#2094)"
else
    FAIL=$((FAIL + 1))
    echo "  FAIL: root-name isolation (#2094; alone='$alone', sequential='$sequential')"
    sed 's/^/    /' "$WORK/rebind-sequential.stderr"
fi
fuzz_test "huge string" "$(python3 -c "print('x is \"' + 'A' * 60000 + '\"')")"
fuzz_test "many assignments" "$(python3 -c "print('\\n'.join(['x is ' + str(i) for i in range(1000)]))")"
fuzz_test "deep nesting" "$(python3 -c "print('if 1 == 1:\\n' + '    if 1 == 1:\\n' * 30 + '        x is 1')")"
fuzz_test "big dict" "$(python3 -c "print('x is {' + ', '.join(['\"k' + str(i) + '\": ' + str(i) for i in range(200)]) + '}')")"
fuzz_test "many match cases" "$(python3 -c "print('match 1:\\n' + ''.join(['    case ' + str(i) + ':\\n        x is ' + str(i) + '\\n' for i in range(100)]))")"

echo ""
echo "Corpus seeds:"
SEEDS=0
SPAWN_SEEDS=0
for f in fuzz/corpus/*.eigs; do
    [ -f "$f" ] || continue
    SEEDS=$((SEEDS + 1))
    if grep -q 'spawn of' "$f" && grep -q 'task_spawn' "$f"; then
        SPAWN_SEEDS=$((SPAWN_SEEDS + 1))
    fi
    run_case "seed: $(basename "$f")" "$f"
done
# A spawn/task seed is the smoke's only witness for per-input thread, task and
# channel handles; losing it, or the whole corpus, must not pass quietly.
if [ "$SEEDS" -eq 0 ] || [ "$SPAWN_SEEDS" -eq 0 ]; then
    echo "  FAIL: corpus ran $SEEDS seed(s), $SPAWN_SEEDS with spawn and task_spawn; need at least one of each"
    FAIL=$((FAIL + 1))
fi

finish
