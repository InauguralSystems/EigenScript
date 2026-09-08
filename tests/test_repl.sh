#!/usr/bin/env bash
# REPL tests (#392).
#
# Two halves:
#   1. The piped/non-tty transcript is a byte-exact golden — the suite (and
#      every consumer that pipes scripts through the binary) depends on the
#      pre-#392 fgets loop surviving the editor refactor unchanged.
#   2. The interactive raw-termios line editor (history, arrows, editing,
#      tab completion, Ctrl-keys) is driven on a real pty by test_repl.py.
#
# Prints "PASS:"/"FAIL:" lines; run_all_tests.sh greps and tallies them.
cd "$(dirname "$0")"
EIGS=${EIGS:-../src/eigenscript}
VER=$("$EIGS" --version)

ok()   { echo "PASS: $1"; }
fail() { echo "FAIL: $1 — $2"; }

# ---- 1. piped path: byte-exact golden transcript ----
IN=$(printf 'x is 5\nx + 1\nif x > 3:\n    y is x * 2\n\ny\nexit\n')
OUT=$(printf '%s\n' "$IN" | "$EIGS" 2>/dev/null)
RC=$?
EXPECTED=$(printf "EigenScript %s\nType 'exit' or Ctrl-D to quit.\n\neigs> => 5\neigs> => 6\neigs> ...   ...   => 10\neigs> => 10\neigs> " "$VER")
if [ "$RC" = "0" ] && [ "$OUT" = "$EXPECTED" ]; then
    ok "REPL piped transcript is byte-exact (prompts, results, block)"
else
    fail "REPL piped transcript" "rc=$RC out='$OUT'"
fi

# piped EOF (no exit command) still leaves rc 0 and the trailing newline
OUT=$(printf '1 + 1\n' | "$EIGS" 2>/dev/null)
RC=$?
EXPECTED=$(printf "EigenScript %s\nType 'exit' or Ctrl-D to quit.\n\neigs> => 2\neigs> " "$VER")
if [ "$RC" = "0" ] && [ "$OUT" = "$EXPECTED" ]; then
    ok "REPL piped EOF transcript is byte-exact"
else
    fail "REPL piped EOF transcript" "rc=$RC out='$OUT'"
fi

# a parse error mid-session recovers and later lines still run
OUT=$(printf 'bad syntax ((((\n7 * 6\nexit\n' | "$EIGS" 2>/dev/null)
if echo "$OUT" | grep -q "=> 42"; then
    ok "REPL piped parse error recovers"
else
    fail "REPL piped parse error recovery" "out='$OUT'"
fi

# ---- 1b. #1109: a failed multi-line unit must not swallow its closing line ----
# The unindented line that closes a block is part of the same unit. When the
# unit never runs (tokenize/parse/compile error) that line used to vanish; it
# is now re-fed as the start of the next unit.

# The issue's repro: the error prints AND `x is 1` / `print of x` still run.
OUT=$(printf 'define f(@) as:\nx is 1\nprint of x\nexit\n' | "$EIGS" 2>&1)
if echo "$OUT" | grep -q "unexpected character '@'" \
   && echo "$OUT" | grep -q "=> 1" \
   && echo "$OUT" | grep -qx "eigs> 1" \
   && ! echo "$OUT" | grep -q "undefined variable 'x'"; then
    ok "REPL failed multi-line unit re-feeds its closing line (#1109)"
else
    fail "REPL #1109 re-feed" "out='$OUT'"
fi

# Control (a): a VALID block closed by an unindented line is still ONE unit —
# byte-exact, so the re-feed cannot have leaked into the success path.
OUT=$(printf 'define f(a) as:\n    return a * 2\nprint of (f of 21)\nexit\n' | "$EIGS" 2>/dev/null)
RC=$?
EXPECTED=$(printf "EigenScript %s\nType 'exit' or Ctrl-D to quit.\n\neigs> ...   ...   42\neigs> " "$VER")
if [ "$RC" = "0" ] && [ "$OUT" = "$EXPECTED" ]; then
    ok "REPL valid block closed by an unindented line stays one unit (#1109 control)"
else
    fail "REPL valid unindent-closed block" "rc=$RC out='$OUT'"
fi

# Control (b): a failed unit closed by a BLANK line reports once and does not
# manufacture a spurious empty unit (nothing is re-fed — there is no line to
# lose), and the next line still runs.
OUT=$(printf 'define f(@) as:\n\nprint of "after"\nexit\n' | "$EIGS" 2>&1)
ERRS=$(echo "$OUT" | grep -c "unexpected character '@'" || true)
if [ "$ERRS" = "1" ] && echo "$OUT" | grep -qx "eigs> after"; then
    ok "REPL blank-line-closed failed unit reports once, no empty unit (#1109 control)"
else
    fail "REPL blank-closed failed unit" "errs=$ERRS out='$OUT'"
fi

# Control (c): two consecutive failed units each report once, and both closing
# lines survive (x and y are both bound, so the third line prints 3).
OUT=$(printf 'define f(@) as:\nx is 1\ndefine g(@) as:\ny is 2\nprint of (x + y)\nexit\n' | "$EIGS" 2>&1)
ERRS=$(echo "$OUT" | grep -c "unexpected character '@'" || true)
if [ "$ERRS" = "2" ] && echo "$OUT" | grep -qx "eigs> 3"; then
    ok "REPL two consecutive failed units each report once (#1109 control)"
else
    fail "REPL two failed units" "errs=$ERRS out='$OUT'"
fi

# The #1102 program pasted into the REPL: the reservation error prints, and the
# `x is 1` line it used to eat now runs — so `report of x` sees two assignments
# and answers `moving`, not the one-assignment `equilibrium`.
OUT=$(printf 'define report(v) as:\n    return "mine"\nx is 1\nx is 2\nprint of (report of x)\nexit\n' | "$EIGS" 2>&1)
if echo "$OUT" | grep -q "reserved observer form" \
   && echo "$OUT" | grep -q "=> 1" \
   && echo "$OUT" | grep -qx "eigs> moving"; then
    ok "REPL #1102 reservation program: error shown and the following lines run (#1109)"
else
    fail "REPL #1102 pasted program" "out='$OUT'"
fi

# The re-fed line goes through the whole line rule, `exit` included: a failed
# unit closed by `exit` now honours it instead of eating it.
printf 'define f(@) as:\nexit\nprint of "AFTER"\n' | "$EIGS" >/dev/null 2>&1
RC=$?
OUT=$(printf 'define f(@) as:\nexit\nprint of "AFTER"\n' | "$EIGS" 2>&1)
if [ "$RC" = "0" ] && ! echo "$OUT" | grep -q "AFTER"; then
    ok "REPL re-fed 'exit' still ends the session (#1109 control)"
else
    fail "REPL re-fed exit" "rc=$RC out='$OUT'"
fi

# ---- 2. interactive editor on a pty ----
if command -v python3 >/dev/null 2>&1; then
    python3 test_repl.py 2>&1 | grep -E "^(PASS|FAIL):"
else
    # python3 is a repo test dependency already (test_lsp.py, doc examples)
    fail "REPL editor pty tests" "python3 not available"
fi
