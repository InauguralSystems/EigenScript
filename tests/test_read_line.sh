#!/bin/bash
# read_line (#558): stream-safe stdin line read. Covers: lines from a PIPE
# (the case read_text of "/dev/stdin" cannot serve — fseek fails on
# unseekable fds), null at EOF, empty-line vs EOF distinction, a final
# line without its trailing newline, CRLF stripping, a seekable redirect,
# and record/replay (tape-first: replay serves the recorded lines with no
# live stdin read — stdin is /dev/null during replay).
#
# Run directly or from run_all_tests.sh. Summary line: READLINE: N passed, M failed.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$TESTS_DIR/.." && pwd)/src"
EIGS="$SRC_DIR/eigenscript"

PASS=0
FAIL=0
TMPDIR=$(mktemp -d -t eigs_readline.XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

if [ ! -x "$EIGS" ]; then
    echo "  FAIL: eigenscript binary not found at $EIGS"
    echo "READLINE: 0 passed, 1 failed"
    exit 1
fi

# Three reads: two lines + EOF.
cat > "$TMPDIR/rl3.eigs" <<'EOF'
a is read_line of null
b is read_line of null
c is read_line of null
print of a
print of b
if c == null:
    print of "EOF-NULL"
EOF

# Two reads: one line + EOF.
cat > "$TMPDIR/rl2.eigs" <<'EOF'
a is read_line of null
b is read_line of null
print of a
if b == null:
    print of "EOF2"
EOF

# ---- pipe: the case the issue is about ----
OUT=$(printf 'hello\nworld\n' | "$EIGS" "$TMPDIR/rl3.eigs" 2>&1)
EXPECT=$'hello\nworld\nEOF-NULL'
[ "$OUT" = "$EXPECT" ] \
    && ok "pipe: lines delivered, newline stripped, null at EOF" \
    || fail "pipe lines" "out='$OUT'"

# ---- empty line is "" (not null) — distinguishable from EOF ----
cat > "$TMPDIR/rl_empty.eigs" <<'EOF'
a is read_line of null
if a == "":
    print of "EMPTY-STR"
if a == null:
    print of "WRONG-NULL"
EOF
OUT=$(printf '\n' | "$EIGS" "$TMPDIR/rl_empty.eigs" 2>&1)
[ "$OUT" = "EMPTY-STR" ] \
    && ok "empty line reads as empty string, not null" \
    || fail "empty line" "out='$OUT'"

# ---- final line without a trailing newline still delivered ----
OUT=$(printf 'tail' | "$EIGS" "$TMPDIR/rl2.eigs" 2>&1)
EXPECT=$'tail\nEOF2'
[ "$OUT" = "$EXPECT" ] \
    && ok "unterminated final line delivered before EOF" \
    || fail "unterminated final line" "out='$OUT'"

# ---- CRLF input: \r\n stripped as one terminator ----
OUT=$(printf 'x\r\n' | "$EIGS" "$TMPDIR/rl2.eigs" 2>&1)
EXPECT=$'x\nEOF2'
[ "$OUT" = "$EXPECT" ] \
    && ok "CRLF terminator stripped" \
    || fail "CRLF strip" "out='$OUT'"

# ---- seekable redirect works identically ----
printf 'f1\nf2\n' > "$TMPDIR/in.txt"
OUT=$("$EIGS" "$TMPDIR/rl3.eigs" < "$TMPDIR/in.txt" 2>&1)
EXPECT=$'f1\nf2\nEOF-NULL'
[ "$OUT" = "$EXPECT" ] \
    && ok "regular-file redirect" \
    || fail "file redirect" "out='$OUT'"

# ---- record/replay: tape-first (#558) ----
TAPE="$TMPDIR/rl.tape"
REC=$(printf 'one\ntwo\n' | EIGS_TRACE="$TAPE" "$EIGS" "$TMPDIR/rl3.eigs" 2>&1)
REP=$(EIGS_REPLAY="$TAPE" "$EIGS" "$TMPDIR/rl3.eigs" </dev/null 2>&1)
EXPECT=$'one\ntwo\nEOF-NULL'
if [ "$REC" = "$EXPECT" ] && [ "$REP" = "$EXPECT" ]; then
    ok "replay serves recorded lines (stdin is /dev/null — no live read)"
else
    fail "record/replay" "rec='$REC' rep='$REP'"
fi

# Exactly one N record per call: 2 lines + the EOF null = 3.
NREC=$(grep -c '^N read_line=' "$TAPE")
[ "$NREC" = "3" ] \
    && ok "tape carries one N record per call (2 lines + EOF null)" \
    || fail "tape N-record count" "got $NREC"

echo "READLINE: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
