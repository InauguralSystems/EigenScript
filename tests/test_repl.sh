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

# ---- 2. interactive editor on a pty ----
if command -v python3 >/dev/null 2>&1; then
    python3 test_repl.py 2>&1 | grep -E "^(PASS|FAIL):"
else
    # python3 is a repo test dependency already (test_lsp.py, doc examples)
    fail "REPL editor pty tests" "python3 not available"
fi
