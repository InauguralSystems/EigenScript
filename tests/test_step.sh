#!/bin/bash
# Tape-stepper tests (#418 eigsdap v1: `eigenscript --step <tape> [src]`).
# Records a tape, then drives the stepper over it with scripted stdin:
# stepping forward/back, binding reconstruction, trajectory labels (the
# runtime's own #294 value-channel classifier), breakpoints, jumps, the
# #411 version refusals, and the --test --trace-on-fail acceptance path.
#
# Run directly or from run_all_tests.sh. Prints PASS:/FAIL: lines and a
# summary. Exit code: 0 if all pass, 1 if any fail.

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$TESTS_DIR/.." && pwd)/src"
EIGS="$SRC_DIR/eigenscript"

PASS=0
FAIL=0
TMPDIR=$(mktemp -d -t eigs_step.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

if [ ! -x "$EIGS" ]; then
    echo "  FAIL: eigenscript binary not found at $EIGS"
    echo "STEP: 0 passed, 1 failed"
    exit 1
fi

# ---- fixture: an oscillator, a halving (converging) binding, a string,
# and one nondet call. 30 halvings of 1024 push the relative step below
# dh_zero (0.001) with a full 10-wide window to spare -> [converged];
# the +1/-1 alternation sign-flips every step -> [oscillating].
FIX="$TMPDIR/fix.eigs"
cat > "$FIX" <<'EOF'
osc is 1
conv is 1024
msg is "hello"
seed is random of null
for i in range of 30:
    osc is 0 - osc
    conv is conv / 2
print of conv
EOF

TAPE="$TMPDIR/fix.tape"
"$EIGS" --trace "$TAPE" "$FIX" > /dev/null 2>&1
if [ -s "$TAPE" ]; then
    ok "fixture records a tape"
else
    fail "fixture records a tape"
    echo "STEP: $PASS passed, $((FAIL)) failed"
    exit 1
fi

drive() {   # drive <commands...> — one stepper session, commands as lines
    printf '%s\n' "$@" | "$EIGS" --step "$TAPE" "$FIX" 2>&1
}

# ---- 1. loads and announces the tape, shows the first stop
OUT=$(drive q)
echo "$OUT" | grep -q "steps, .* assigns" && echo "$OUT" | grep -q "^step 1/" \
    && ok "loads tape and shows first stop" \
    || fail "loads tape and shows first stop" "$(echo "$OUT" | head -2)"

# ---- 2. forward stepping walks the L records and shows source + events
OUT=$(drive s s q)
echo "$OUT" | grep -q "step 3/.*line 2" \
    && echo "$OUT" | grep -q "| conv is 1024" \
    && echo "$OUT" | grep -q "A conv=1024" \
    && ok "forward step shows line, source text, assignment events" \
    || fail "forward step shows line, source text, assignment events"

# ---- 3. nondet events surface at their step
OUT=$(drive "s 4" q)
echo "$OUT" | grep -q "N random=" \
    && ok "nondet record shown at its step" \
    || fail "nondet record shown at its step"

# ---- 4. bindings at end of tape: values + trajectory labels from the
#         runtime's own classifier
OUT=$(drive "s 200" s p q)
echo "$OUT" | grep -q "at end of tape" \
    && ok "stepping past the end reports end of tape" \
    || fail "stepping past the end reports end of tape"
echo "$OUT" | grep -Eq "^conv = .*\[converged\]" \
    && echo "$OUT" | grep -Eq "^osc = (-)?1  \[oscillating\]" \
    && ok "end-of-tape labels: conv converged, osc oscillating" \
    || fail "end-of-tape labels: conv converged, osc oscillating"
echo "$OUT" | grep -Eq '^msg = "hello"  \(1 assign\)' \
    && ok "non-numeric binding shows value, no trajectory label" \
    || fail "non-numeric binding shows value, no trajectory label"

# ---- 5. THE ACCEPTANCE CHECK (#418): step back and watch the label flip.
#         At the end conv is [converged]; 40 steps earlier it is still
#         mid-descent -> [moving]. Same binding, same tape, different moment.
OUT=$(drive "s 200" "b 40" p q)
echo "$OUT" | grep -Eq "^conv = .*\[moving\]" \
    && ok "stepping back flips conv's label converged -> moving" \
    || fail "stepping back flips conv's label converged -> moving"

# ---- 6. breakpoints: br + c stops only on that line; rc goes back
OUT=$(drive "br 7" c c rc q)
HITS=$(echo "$OUT" | grep -c "line 7$")
[ "$HITS" -ge 3 ] \
    && ok "breakpoint continue/reverse-continue stop on line 7" \
    || fail "breakpoint continue/reverse-continue stop on line 7" "hits=$HITS"

# ---- 7. jump to line, both directions
OUT=$(drive "j 8" "jb 1" q)
echo "$OUT" | grep -q "line 8" && echo "$OUT" | grep -q "line 1" \
    && ok "jump forward and backward to a line" \
    || fail "jump forward and backward to a line"

# ---- 8. trajectory view: per-assign running labels
OUT=$(drive "s 200" "t conv" q)
echo "$OUT" | grep -q "^conv: 31 assigns" \
    && echo "$OUT" | grep -q "earlier assign(s) elided" \
    && echo "$OUT" | grep -Eq "\[moving\]" \
    && echo "$OUT" | grep -Eq "\[converged\]" \
    && ok "trajectory view shows running classification" \
    || fail "trajectory view shows running classification"

# ---- 9. #411 version refusals, the replay rule verbatim: exit 3
sed '1s/.*/V 1 0.0.0-other/' "$TAPE" > "$TMPDIR/rt.tape"
echo q | "$EIGS" --step "$TMPDIR/rt.tape" > /dev/null 2>"$TMPDIR/rt.err"
[ $? -eq 3 ] && grep -q "refusing to step" "$TMPDIR/rt.err" \
    && ok "runtime-version mismatch refused with exit 3" \
    || fail "runtime-version mismatch refused with exit 3"

sed '1s/.*/V 99 0.29.0/' "$TAPE" > "$TMPDIR/fmt.tape"
echo q | "$EIGS" --step "$TMPDIR/fmt.tape" > /dev/null 2>"$TMPDIR/fmt.err"
[ $? -eq 3 ] && grep -q "tape format v99" "$TMPDIR/fmt.err" \
    && ok "format-version mismatch refused with exit 3" \
    || fail "format-version mismatch refused with exit 3"

: > "$TMPDIR/empty.tape"
echo q | "$EIGS" --step "$TMPDIR/empty.tape" > /dev/null 2>&1
[ $? -eq 3 ] \
    && ok "empty tape refused with exit 3" \
    || fail "empty tape refused with exit 3"

# ---- 10. acceptance: a --test --trace-on-fail tape drives the stepper
FAILDIR="$TMPDIR/suite"
mkdir -p "$FAILDIR"
cat > "$FAILDIR/test_boom.eigs" <<'EOF'
x is 2
for i in range of 6:
    x is x * x
exit of 1
EOF
TR_OUT=$("$EIGS" --test --trace-on-fail "$FAILDIR" 2>&1)
FAIL_TAPE=$(echo "$TR_OUT" | grep -o 'EIGS_REPLAY=[^ ]*' | head -1 | cut -d= -f2)
if [ -n "$FAIL_TAPE" ] && [ -f "$FAIL_TAPE" ]; then
    OUT=$(printf 's 200\np x\nq\n' | "$EIGS" --step "$FAIL_TAPE" 2>&1)
    echo "$OUT" | grep -Eq "^x = .*\[diverging|^x = .*\[moving" \
        && ok "--trace-on-fail tape steps and classifies the culprit" \
        || fail "--trace-on-fail tape steps and classifies the culprit" \
                "$(echo "$OUT" | grep '^x' | head -1)"
    rm -f "$FAIL_TAPE"
else
    fail "--trace-on-fail tape steps and classifies the culprit" "no tape path in runner output"
fi

# ---- 11. EOF on stdin is a clean quit (exit 0)
printf '' | "$EIGS" --step "$TAPE" > /dev/null 2>&1
[ $? -eq 0 ] \
    && ok "EOF quits cleanly" \
    || fail "EOF quits cleanly"

# ---- 12. #539 v2: scope-qualified locals — a function-local i and the
# top-level i are separate streams; two invocations of the same function
# never merge; inside the frame the local shadows the outer binding.
SCOPE_FIX="$TMPDIR/scope.eigs"
SCOPE_TAPE="$TMPDIR/scope.tape"
cat > "$SCOPE_FIX" <<'EOF'
define work(n) as:
    i is n * 10
    i is i + 1
    return i
i is 1
r1 is work of 2
i is 2
r2 is work of 3
i is 3
EOF
EIGS_TRACE="$SCOPE_TAPE" "$EIGS" "$SCOPE_FIX" > /dev/null 2>&1

grep -q '^S work 1 ' "$SCOPE_TAPE" \
    && ok "tape carries S scope-transition records (v2)" \
    || fail "tape carries S scope-transition records (v2)"

# two work() invocations = two distinct frame serials on their S records
NSER=$(grep '^S work 1 ' "$SCOPE_TAPE" | sort -u | wc -l)
[ "$NSER" -eq 2 ] \
    && ok "same-function invocations get distinct frame serials" \
    || fail "same-function invocations get distinct frame serials" "got $NSER"

# at module end: module i folded alone (3 assigns, value 3) — the four
# fn-local writes must not pollute the stream (the v1 merge bug)
OUT=$(printf 's 20\np i\nt i\nq\n' | "$EIGS" --step "$SCOPE_TAPE" "$SCOPE_FIX" 2>&1)
echo "$OUT" | grep -q "^i = 3 .*(3 assigns)" \
    && ok "module-level i folds only its own stream" \
    || fail "module-level i folds only its own stream" \
            "$(echo "$OUT" | grep '^i =' | head -1)"

# inside the second work frame (step 11 = its 'i is i + 1' line): the
# frame-local i (31, 2 assigns, {in work}) shadows the module i
OUT=$(printf 's 10\np\nt i\nq\n' | "$EIGS" --step "$SCOPE_TAPE" "$SCOPE_FIX" 2>&1)
echo "$OUT" | grep -q "^i = 31 .*{in work}" \
    && ok "frame-local i shadows module i inside the frame" \
    || fail "frame-local i shadows module i inside the frame" \
            "$(echo "$OUT" | grep '^i =' | head -1)"
echo "$OUT" | grep -q "(i in work, frame #" \
    && ok "trajectory resolves to the frame's own stream" \
    || fail "trajectory resolves to the frame's own stream"
# the module i (value 2 at that point) must NOT appear — shadowed
echo "$OUT" | grep -q "^i = 2 " \
    && fail "shadowed module i leaks into frame bindings" \
    || ok "shadowed module i stays hidden inside the frame"

echo "STEP: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
