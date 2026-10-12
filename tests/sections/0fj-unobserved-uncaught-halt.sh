# An uncaught error inside `unobserved:` must not leave a REPL session (or any
# state that runs again) unobserved: the next line's predicate answered
# "the observer is off" forever (fuzz invariant harness, 2026-10-12).
echo "[0fj] Uncaught error inside unobserved: restores observer depth"
UNOBS_OUT=$(printf 'unobserved:\n    throw of "boom"\n\nx is 1\nx is 2\nprint of (converged of x)\n' | $EIGS_TMO ./eigenscript 2>&1)
TOTAL=$((TOTAL + 1))
if printf '%s\n' "$UNOBS_OUT" | grep -q 'boom' &&
   ! printf '%s\n' "$UNOBS_OUT" | grep -q 'observer is off' &&
   printf '%s\n' "$UNOBS_OUT" | grep -qE '(^|> )(true|false)$'; then
    PASS=$((PASS + 1)); echo "  PASS: a predicate after an uncaught error in unobserved: is answered"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: observer stayed off after an uncaught error in unobserved: ($(printf '%s' "$UNOBS_OUT" | tr '\n' ' ' | cut -c1-200))"
fi
echo ""
