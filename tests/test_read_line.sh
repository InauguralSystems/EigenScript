#!/bin/bash
# read_line (#558): stream-safe stdin line read. Covers: lines from a PIPE
# (the case read_text of "/dev/stdin" cannot serve — fseek fails on
# unseekable fds), null at EOF, empty-line vs EOF distinction, a final
# line without a trailing newline, CRLF preservation, a seekable redirect,
# and record/replay (tape-first: replay serves the recorded lines with no
# live stdin read — stdin is /dev/null during replay). Line terminators are
# returned byte-for-byte, so CR and a final newline remain observable.
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

cat > "$TMPDIR/rl_exact_final.eigs" <<'EOF'
a is read_line of null
b is read_line of null
c is read_line of null
assert of [a == "a\r\n", "first line preserves CRLF"]
assert of [b == "b\n", "final line preserves newline"]
assert of [c == null, "EOF is null"]
print of "BYTE-EXACT-FINAL"
EOF

cat > "$TMPDIR/rl_exact_unterminated.eigs" <<'EOF'
a is read_line of null
b is read_line of null
c is read_line of null
assert of [a == "a\r\n", "first line preserves CRLF"]
assert of [b == "b", "unterminated final line has no newline"]
assert of [c == null, "EOF is null"]
print of "BYTE-EXACT-UNTERMINATED"
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
EXPECT=$'hello\n\nworld\n\nEOF-NULL'
[ "$OUT" = "$EXPECT" ] \
    && ok "pipe: lines delivered byte-exactly, null at EOF" \
    || fail "pipe lines" "out='$OUT'"

# ---- empty line is "\n" (not null) — distinguishable from EOF ----
cat > "$TMPDIR/rl_empty.eigs" <<'EOF'
a is read_line of null
if a == "\n":
    print of "EMPTY-STR"
if a == null:
    print of "WRONG-NULL"
EOF
OUT=$(printf '\n' | "$EIGS" "$TMPDIR/rl_empty.eigs" 2>&1)
[ "$OUT" = "EMPTY-STR" ] \
    && ok "empty line preserves its newline and is not null" \
    || fail "empty line" "out='$OUT'"

# ---- final line without a trailing newline still delivered ----
OUT=$(printf 'tail' | "$EIGS" "$TMPDIR/rl2.eigs" 2>&1)
EXPECT=$'tail\nEOF2'
[ "$OUT" = "$EXPECT" ] \
    && ok "unterminated final line delivered before EOF" \
    || fail "unterminated final line" "out='$OUT'"

# ---- byte exactness and final-newline distinction, for pipe and file ----
for source in pipe file; do
    if [ "$source" = pipe ]; then
        OUT=$(printf 'a\r\nb\n' | "$EIGS" "$TMPDIR/rl_exact_final.eigs" 2>&1)
    else
        printf 'a\r\nb\n' > "$TMPDIR/exact.in"
        OUT=$("$EIGS" "$TMPDIR/rl_exact_final.eigs" < "$TMPDIR/exact.in" 2>&1)
    fi
    [ "$OUT" = "BYTE-EXACT-FINAL" ] \
        && ok "$source: CRLF and final newline preserved" \
        || fail "$source exact final" "out='$OUT'"

    if [ "$source" = pipe ]; then
        OUT=$(printf 'a\r\nb' | "$EIGS" "$TMPDIR/rl_exact_unterminated.eigs" 2>&1)
    else
        printf 'a\r\nb' > "$TMPDIR/exact.in"
        OUT=$("$EIGS" "$TMPDIR/rl_exact_unterminated.eigs" < "$TMPDIR/exact.in" 2>&1)
    fi
    [ "$OUT" = "BYTE-EXACT-UNTERMINATED" ] \
        && ok "$source: missing final newline remains observable" \
        || fail "$source exact unterminated" "out='$OUT'"
done

# ---- seekable redirect works identically ----
printf 'f1\nf2\n' > "$TMPDIR/in.txt"
OUT=$("$EIGS" "$TMPDIR/rl3.eigs" < "$TMPDIR/in.txt" 2>&1)
EXPECT=$'f1\n\nf2\n\nEOF-NULL'
[ "$OUT" = "$EXPECT" ] \
    && ok "regular-file redirect" \
    || fail "file redirect" "out='$OUT'"

# ---- record/replay: tape-first (#558) ----
TAPE="$TMPDIR/rl.tape"
REC=$(printf 'one\ntwo\n' | EIGS_TRACE="$TAPE" "$EIGS" "$TMPDIR/rl3.eigs" 2>&1)
REP=$(EIGS_REPLAY="$TAPE" "$EIGS" "$TMPDIR/rl3.eigs" </dev/null 2>&1)
EXPECT=$'one\n\ntwo\n\nEOF-NULL'
if [ "$REC" = "$EXPECT" ] && [ "$REP" = "$EXPECT" ]; then
    ok "replay serves recorded lines (stdin is /dev/null — no live read)"
else
    fail "record/replay" "rec='$REC' rep='$REP'"
fi

# Exactly one N record per call: 2 lines + the EOF null = 3.
NREC=$(grep -c '^N [0-9][0-9]* read_line=' "$TAPE")
[ "$NREC" = "3" ] \
    && ok "tape carries one N record per call (2 lines + EOF null)" \
    || fail "tape N-record count" "got $NREC"

echo "READLINE: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
