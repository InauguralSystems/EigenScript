#!/bin/bash
# Test the EigenScript formatter (--fmt)
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$TESTS_DIR/../src/eigenscript"

# Formatter round trips execute programs only to compare before/after
# semantics; they are not suite assertion invocations.  Do not let the outer
# verdict-propagation calibration turn those comparison operands into ledger
# entries (or make two equally forced failures look like propagation).
unset EIGS_TEST_FORCE_SUMMARY_FAILURE EIGS_TEST_FORCE_SUMMARY_LEDGER EIGS_TEST_SCRIPT_PATH

PASS=0
FAIL=0
TOTAL=0

check() {
    TOTAL=$((TOTAL + 1))
    local test_name="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  PASS: $test_name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $test_name"
        echo "    expected: |$(echo "$expected" | head -3)|"
        echo "    actual:   |$(echo "$actual" | head -3)|"
        FAIL=$((FAIL + 1))
    fi
}

fmt_str() {
    local input="$1"
    local tmpf
    tmpf=$(mktemp /tmp/fmt_test_XXXXXX.eigs)
    printf '%s' "$input" > "$tmpf"
    $EIGS --fmt "$tmpf" 2>/dev/null
    rm -f "$tmpf"
}

echo "=== Formatter Tests ==="

# --- Indentation normalization ---
ACTUAL=$(fmt_str "$(printf 'define foo(x) as:\n  return x\n')")
EXPECTED=$(printf 'define foo(x) as:\n    return x\n')
check "indent normalization (2->4)" "$ACTUAL" "$EXPECTED"

# --- #1370: lexer and formatter agree on mixed whitespace tab stops ---
# Each pair of body lines has the same visual width.  Run the original and the
# formatted result: matching pretty text alone would not prove that the lexer
# assigned both lines to the same block before formatting.
MIXED_DIR=$(mktemp -d /tmp/fmt_mixed_indent_XXXXXX)
printf 'if 1 == 1:\n\t \tprint of "tab-space-tab"\n\t    print of "tab-spaces"\n' > "$MIXED_DIR/tabs.eigs"
printf 'if 1 == 1:\n  \tprint of "spaces-tab"\n    print of "spaces"\n' > "$MIXED_DIR/spaces.eigs"
for mixed in tabs spaces; do
    $EIGS "$MIXED_DIR/$mixed.eigs" > "$MIXED_DIR/$mixed.before" 2>&1
    BEFORE_RC=$?
    $EIGS --fmt "$MIXED_DIR/$mixed.eigs" > "$MIXED_DIR/$mixed.formatted" 2>/dev/null
    FMT_RC=$?
    $EIGS "$MIXED_DIR/$mixed.formatted" > "$MIXED_DIR/$mixed.after" 2>&1
    AFTER_RC=$?
    check "mixed-indent $mixed keeps one block before and after --fmt" \
          "before_rc=$BEFORE_RC fmt_rc=$FMT_RC after_rc=$AFTER_RC same=$(cmp -s "$MIXED_DIR/$mixed.before" "$MIXED_DIR/$mixed.after" && echo yes || echo no)" \
          "before_rc=0 fmt_rc=0 after_rc=0 same=yes"
done
rm -rf "$MIXED_DIR"

# --- Trailing whitespace removal ---
ACTUAL=$(fmt_str "$(printf 'x is 42   \ny is 10  \n')")
EXPECTED=$(printf 'x is 42\ny is 10\n')
check "trailing whitespace removal" "$ACTUAL" "$EXPECTED"

# --- Preserve physical blank lines (`at <line>` is observable) ---
ACTUAL=$(fmt_str "$(printf 'x is 1\n\n\n\ny is 2\n')")
EXPECTED=$(printf 'x is 1\n\n\n\ny is 2\n')
check "preserve multiple blank lines" "$ACTUAL" "$EXPECTED"

# --- Space after comma ---
ACTUAL=$(fmt_str "$(printf '[1,2,3]\n')")
EXPECTED=$(printf '[1, 2, 3]\n')
check "space after comma" "$ACTUAL" "$EXPECTED"

# --- No space before comma ---
ACTUAL=$(fmt_str "$(printf '[1 , 2 , 3]\n')")
EXPECTED=$(printf '[1, 2, 3]\n')
check "no space before comma" "$ACTUAL" "$EXPECTED"

# --- No space inside brackets ---
ACTUAL=$(fmt_str "$(printf '[ 1, 2, 3 ]\n')")
EXPECTED=$(printf '[1, 2, 3]\n')
check "no space inside brackets" "$ACTUAL" "$EXPECTED"

# --- Comment spacing ---
ACTUAL=$(fmt_str "$(printf '#comment here\n')")
EXPECTED=$(printf '# comment here\n')
check "space after # in comment" "$ACTUAL" "$EXPECTED"

# --- Operator spacing ---
ACTUAL=$(fmt_str "$(printf 'x is 1+2\n')")
EXPECTED=$(printf 'x is 1 + 2\n')
check "space around +" "$ACTUAL" "$EXPECTED"

# --- Comparison operator spacing ---
ACTUAL=$(fmt_str "$(printf 'if x==5:\n')")
EXPECTED=$(printf 'if x == 5:\n')
check "space around ==" "$ACTUAL" "$EXPECTED"

# --- Final newline ---
ACTUAL=$(fmt_str "$(printf 'x is 42')")
EXPECTED=$(printf 'x is 42\n')
check "final newline" "$ACTUAL" "$EXPECTED"

# --- String content preserved ---
ACTUAL=$(fmt_str "$(printf 'x is "hello,world"\n')")
EXPECTED=$(printf 'x is "hello,world"\n')
check "string content not modified" "$ACTUAL" "$EXPECTED"

# Literal bytes are opaque, but they remain atoms in the whole-line spacing
# pass so punctuation on either side is normalized (#1581 round 3).
ACTUAL=$(fmt_str "$(printf 'print of \"a\"+\"b\"\n')")
check "operator spacing across two literals" "$ACTUAL" "$(printf 'print of \"a\" + \"b\"\n')"

ACTUAL=$(fmt_str "$(printf '[\"a\",\"b\"]\n')")
check "comma spacing across literals" "$ACTUAL" "$(printf '[\"a\", \"b\"]\n')"

ACTUAL=$(fmt_str "$(printf 'x is f\"{y}\"+\"z\"\n')")
check "operator spacing across f-string literal" "$ACTUAL" "$(printf 'x is f\"{y}\" + \"z\"\n')"

ACTUAL=$(fmt_str "$(printf 'value is \"a\nb\"+x\n')")
check "operator after multiline literal closing line" "$ACTUAL" "$(printf 'value is \"a\nb\" + x\n')"

ACTUAL=$(fmt_str "$(printf 'values is [\"a\nb\",2]\n')")
check "comma after multiline literal closing line" "$ACTUAL" "$(printf 'values is [\"a\nb\", 2]\n')"

# --- Idempotency on clean file ---
ORIGINAL=$($EIGS --fmt examples/hello.eigs 2>/dev/null)
TMPF=$(mktemp /tmp/fmt_test_XXXXXX.eigs)
printf '%s' "$ORIGINAL" > "$TMPF"
DOUBLE=$($EIGS --fmt "$TMPF" 2>/dev/null)
rm -f "$TMPF"
check "idempotent on hello.eigs" "$DOUBLE" "$ORIGINAL"

# --- Do not insert lines (physical line numbers are observable) ---
ACTUAL=$(fmt_str "$(printf 'define foo() as:\n    return 1\ndefine bar() as:\n    return 2\n')")
EXPECTED=$(printf 'define foo() as:\n    return 1\ndefine bar() as:\n    return 2\n')
check "formatter does not insert semantic lines between defines" "$ACTUAL" "$EXPECTED"

# --- Write mode ---
TMPFILE=$(mktemp /tmp/fmt_test_XXXXXX.eigs)
printf 'x is 1+2\n' > "$TMPFILE"
$EIGS --fmt --write "$TMPFILE" 2>/dev/null
ACTUAL=$(cat "$TMPFILE")
EXPECTED=$(printf 'x is 1 + 2\n')
check "--write mode" "$ACTUAL" "$EXPECTED"
rm -f "$TMPFILE"

# #1758 N4/Q6: formatter inherits the lexer's single operator table.
ACTUAL=$(fmt_str "$(printf 'x is -7//2\nx//=2\n')")
check "// and //= spaced whole" "$ACTUAL" "$(printf 'x is -7 // 2\nx //= 2\n')"

# --- Multi-char operators must not be split (#729) ---
# The third pass of fix_spacing is character-level; any operator missing from
# its multi-char table gets split by the single-char branches, which silently
# corrupts the file under --write. One case per operator that was broken.
ACTUAL=$(fmt_str "$(printf 'x += 1\n')")
check "+= preserved" "$ACTUAL" "$(printf 'x += 1\n')"

ACTUAL=$(fmt_str "$(printf 'x <<= 2\n')")
check "<<= preserved" "$ACTUAL" "$(printf 'x <<= 2\n')"

ACTUAL=$(fmt_str "$(printf 'x >>= 2\n')")
check ">>= preserved" "$ACTUAL" "$(printf 'x >>= 2\n')"

ACTUAL=$(fmt_str "$(printf 'y is x >> 1\n')")
check ">> preserved" "$ACTUAL" "$(printf 'y is x >> 1\n')"

ACTUAL=$(fmt_str "$(printf 'y is x << 1\n')")
check "<< preserved" "$ACTUAL" "$(printf 'y is x << 1\n')"

ACTUAL=$(fmt_str "$(printf 'f is (n) => n + 1\n')")
check "=> preserved" "$ACTUAL" "$(printf 'f is (n) => n + 1\n')"

ACTUAL=$(fmt_str "$(printf 'g is [1, 2, 3] |> len\n')")
check "|> preserved" "$ACTUAL" "$(printf 'g is [1, 2, 3] |> len\n')"

ACTUAL=$(fmt_str "$(printf 'b is 1.5e+10\n')")
check "exponent literal preserved" "$ACTUAL" "$(printf 'b is 1.5e+10\n')"

ACTUAL=$(fmt_str "$(printf 'b is 1.5e-10\n')")
check "negative exponent preserved" "$ACTUAL" "$(printf 'b is 1.5e-10\n')"

# The same operators, unspaced on input: the formatter should ADD the outer
# spaces without splitting the operator itself.
ACTUAL=$(fmt_str "$(printf 'x+=1\n')")
check "+= spaced, not split" "$ACTUAL" "$(printf 'x += 1\n')"

ACTUAL=$(fmt_str "$(printf 'x<<=2\n')")
check "<<= spaced, not split" "$ACTUAL" "$(printf 'x <<= 2\n')"

ACTUAL=$(fmt_str "$(printf 'y is a>>b\n')")
check ">> spaced, not split" "$ACTUAL" "$(printf 'y is a >> b\n')"

ACTUAL=$(fmt_str "$(printf 'f is (n)=>n+1\n')")
check "=> spaced, not split" "$ACTUAL" "$(printf 'f is (n) => n + 1\n')"

# --- #1238: trace/replay environment is irrelevant to --fmt ---
# Nothing executes under --fmt, so an inherited EIGS_REPLAY must not fail it
# and an inherited EIGS_TRACE must not create or truncate a tape. Exit status
# is captured directly: fmt_str's trailing rm would hide it.
TR_DIR=$(mktemp -d /tmp/fmt_trace_XXXXXX)
printf 'x is 1+2\nprint of x\n' > "$TR_DIR/input.eigs"
TR_WANT=$(printf 'x is 1 + 2\nprint of x\n')
TR_OUT=$(env -u EIGS_TRACE EIGS_REPLAY="$TR_DIR/missing.tape" $EIGS --fmt "$TR_DIR/input.eigs" 2>"$TR_DIR/err"); TR_RC=$?
check "--fmt ignores a missing EIGS_REPLAY tape" "rc=$TR_RC err=$(cat "$TR_DIR/err")|$TR_OUT" "rc=0 err=|$TR_WANT"
printf 'DO-NOT-OVERWRITE\n' > "$TR_DIR/sentinel.tape"
TR_OUT=$(env -u EIGS_REPLAY EIGS_TRACE="$TR_DIR/sentinel.tape" $EIGS --fmt "$TR_DIR/input.eigs" 2>/dev/null); TR_RC=$?
check "--fmt leaves an existing EIGS_TRACE file unchanged" "rc=$TR_RC tape=$(cat "$TR_DIR/sentinel.tape")|$TR_OUT" "rc=0 tape=DO-NOT-OVERWRITE|$TR_WANT"
env -u EIGS_REPLAY EIGS_TRACE="$TR_DIR/fresh.tape" $EIGS --fmt "$TR_DIR/input.eigs" >/dev/null 2>&1; TR_RC=$?
check "--fmt creates no EIGS_TRACE file" "rc=$TR_RC exists=$([ -e "$TR_DIR/fresh.tape" ] && echo yes || echo no)" "rc=0 exists=no"
# --fmt --write under both variables: only the source file changes
cp "$TR_DIR/input.eigs" "$TR_DIR/w.eigs"
EIGS_REPLAY="$TR_DIR/missing.tape" EIGS_TRACE="$TR_DIR/sentinel.tape" $EIGS --fmt --write "$TR_DIR/w.eigs" >/dev/null 2>&1; TR_RC=$?
check "--fmt --write ignores trace/replay and rewrites only the source" \
      "rc=$TR_RC tape=$(cat "$TR_DIR/sentinel.tape") src=$(cat "$TR_DIR/w.eigs") files=$(ls "$TR_DIR" | tr '\n' ' ')" \
      "rc=0 tape=DO-NOT-OVERWRITE src=$TR_WANT files=err input.eigs sentinel.tape w.eigs "
# a formatter error (unreadable input) keeps its own nonzero status
env -u EIGS_TRACE -u EIGS_REPLAY $EIGS --fmt "$TR_DIR/absent.eigs" >/dev/null 2>&1; TR_BASE=$?
EIGS_REPLAY="$TR_DIR/missing.tape" EIGS_TRACE="$TR_DIR/sentinel.tape" $EIGS --fmt "$TR_DIR/absent.eigs" >/dev/null 2>&1; TR_RC=$?
check "--fmt error status unchanged by trace/replay env" "base_nonzero=$([ "$TR_BASE" -ne 0 ] && echo yes) rc=$TR_RC tape=$(cat "$TR_DIR/sentinel.tape")" "base_nonzero=yes rc=$TR_BASE tape=DO-NOT-OVERWRITE"
# control: a normal script run still records under EIGS_TRACE
env -u EIGS_REPLAY EIGS_TRACE="$TR_DIR/run.tape" $EIGS "$TR_DIR/input.eigs" >/dev/null 2>&1; TR_RC=$?
check "control: running a script still records a tape" "rc=$TR_RC v=$(head -c 2 "$TR_DIR/run.tape" 2>/dev/null)" "rc=0 v=V "
env -u EIGS_TRACE EIGS_REPLAY="$TR_DIR/run.tape" $EIGS "$TR_DIR/input.eigs" > "$TR_DIR/replay.out" 2>&1; TR_RC=$?
check "control: and replays it" "rc=$TR_RC out=$(cat "$TR_DIR/replay.out")" "rc=0 out=3"
rm -rf "$TR_DIR"

# --- Corpus property: formatting a valid program must leave it valid (#729) ---
# --- #1245/#1246/#1581: lexer-owned literal and layout boundaries ---
REG_DIR=$(mktemp -d /tmp/fmt_lexer_layout_XXXXXX)
trap 'rm -rf "$REG_DIR"' EXIT

check_roundtrip() {
    local name="$1" src="$2" before_rc fmt_rc after_rc fixed_rc
    printf '%s' "$src" > "$REG_DIR/in.eigs"
    "$EIGS" "$REG_DIR/in.eigs" >"$REG_DIR/before" 2>"$REG_DIR/before.err"; before_rc=$?
    "$EIGS" --fmt "$REG_DIR/in.eigs" >"$REG_DIR/once.eigs" 2>"$REG_DIR/fmt.err"; fmt_rc=$?
    "$EIGS" "$REG_DIR/once.eigs" >"$REG_DIR/after" 2>"$REG_DIR/after.err"; after_rc=$?
    "$EIGS" --fmt "$REG_DIR/once.eigs" >"$REG_DIR/twice.eigs" 2>/dev/null; fixed_rc=$?
    check "$name executes identically and formatting is idempotent" \
        "before=$before_rc fmt=$fmt_rc after=$after_rc fixed=$fixed_rc stdout=$([ -f "$REG_DIR/after" ] && cmp -s "$REG_DIR/before" "$REG_DIR/after" && echo same) source=$(cmp -s "$REG_DIR/once.eigs" "$REG_DIR/twice.eigs" && echo fixed)" \
        "before=0 fmt=0 after=0 fixed=0 stdout=same source=fixed"
}

check_roundtrip "#1245 multiline literal bytes" "$(printf 'value is \"start\n  a+b  \nend\"\nprint of value\n')"
check_roundtrip "multiline blank/operator/comment text and single-line control" "$(printf 'value is \"one\n\n  x==y # not a comment  \nend\"\ncontrol is \"a+b # text\"\nprint of value\nprint of control\n')"
check_roundtrip "#1581 nested quote f-string" 's is f"{ "\"" }"
print of s
'
check_roundtrip "#1581 list continuation after string f" 'xs is ["f",
  1+2,
    "third"]
print of len of xs
'
check "#1581 list continuation still formats later code" \
      "$(sed -n '2p' "$REG_DIR/once.eigs")" "  1 + 2,"
# A rejected token stream is never partially emitted or written back.
printf 'x is "unterminated\n' > "$REG_DIR/rejected.eigs"
cp "$REG_DIR/rejected.eigs" "$REG_DIR/rejected.before"
"$EIGS" --fmt --write "$REG_DIR/rejected.eigs" > /dev/null 2>"$REG_DIR/rejected.err"; rejected_rc=$?
check "lexer rejection leaves --write input unchanged with lexer error" \
      "rc_nonzero=$([ "$rejected_rc" -ne 0 ] && echo yes) same=$(cmp -s "$REG_DIR/rejected.before" "$REG_DIR/rejected.eigs" && echo yes) error=$(grep -c 'unterminated string' "$REG_DIR/rejected.err")" \
      "rc_nonzero=yes same=yes error=1"
check_roundtrip "#1246 unequal 4 then 6 spaces" 'if 1:
    if 1:
      print of 7
print of 9
'
check_roundtrip "sibling blocks and every dedent level" 'if 1:
  if 1:
      print of 1
  if 1:
    print of 2
print of 3
'
check_roundtrip "ordinary two-space indentation" 'if 1:
  if 1:
    print of 2
'
check_roundtrip "ordinary four-space indentation" 'if 1:
    if 1:
        print of 4
'

# A CR belonging to the source line ending is normalized, but a CR inside a
# multiline literal is program data. Compare stdout as bytes, not shell text.
python3 - "$REG_DIR/crlf.eigs" <<'PY'
import sys
open(sys.argv[1], "wb").write(
    b'value is "start\r\n\t# a+b  \r\nback\\\r\nslash"\r\nprint of value\r\n')
PY
"$EIGS" "$REG_DIR/crlf.eigs" >"$REG_DIR/cr.before"
"$EIGS" --fmt "$REG_DIR/crlf.eigs" >"$REG_DIR/cr.formatted"
"$EIGS" "$REG_DIR/cr.formatted" >"$REG_DIR/cr.after"
check "multiline literal preserves CR bytes" \
      "$(cmp -s "$REG_DIR/cr.before" "$REG_DIR/cr.after" && echo same)" "same"

COMMENT_INPUT='if 1:
  #depth one
  if 1:
      # depth two
      print of 7
  # sibling one
  print of 9
#top
'
COMMENT_WANT='if 1:
    # depth one
    if 1:
        # depth two
        print of 7
    # sibling one
    print of 9
# top
'
check "standalone comments preserve nested sibling placement" \
      "$(fmt_str "$COMMENT_INPUT")" "$(printf '%s' "$COMMENT_WANT")"

check "trailing block comment stays in block across dedent" \
      "$(fmt_str 'if 1:
    print of 1
    # trailing in block
print of 2
')" "$(printf 'if 1:\n    print of 1\n    # trailing in block\nprint of 2\n')"

check "comment deeper than every open block uses deepest open block" \
      "$(fmt_str 'if 1:
    print of 1
            # over-indented comment
print of 2
')" "$(printf 'if 1:\n    print of 1\n    # over-indented comment\nprint of 2\n')"

check "comment after opener follows first body statement" \
      "$(fmt_str 'if 1:
# body introduction
    print of 1
')" "$(printf 'if 1:\n    # body introduction\n    print of 1\n')"

check "comments at every open column survive a two-level dedent" \
      "$(fmt_str 'if 1:
    if 1:
        print of 1
        # depth two
    # depth one
# top
print of 2
')" "$(printf 'if 1:\n    if 1:\n        print of 1\n        # depth two\n    # depth one\n# top\nprint of 2\n')"

# The doc executor owns fence parsing, while this formatter suite owns the
# formatting contract. Consume fences only through the executor's documented
# extraction interface, then require acceptance and a fixed point.
DOC_DIR="$REG_DIR/doc-fences"
DOC_LIST="$REG_DIR/doc-fences.list"
python3 "$TESTS_DIR/test_doc_examples.py" --extract "$DOC_DIR" \
    "$TESTS_DIR/../README.md" "$TESTS_DIR/../docs/"*.md "$TESTS_DIR/../docs/llms.txt" \
    >"$DOC_LIST"
DOC_EXTRACT_RC=$?
DOC_FMT_BAD=0 DOC_FMT_N=0
while IFS= read -r fence; do
    DOC_FMT_N=$((DOC_FMT_N + 1))
    "$EIGS" --fmt "$fence" >"$REG_DIR/doc.once" 2>/dev/null || { DOC_FMT_BAD=$((DOC_FMT_BAD + 1)); continue; }
    "$EIGS" --fmt "$REG_DIR/doc.once" >"$REG_DIR/doc.twice" 2>/dev/null || { DOC_FMT_BAD=$((DOC_FMT_BAD + 1)); continue; }
    cmp -s "$REG_DIR/doc.once" "$REG_DIR/doc.twice" || DOC_FMT_BAD=$((DOC_FMT_BAD + 1))
done <"$DOC_LIST"
check "doc fences format through the executor extraction interface" \
      "extract=$DOC_EXTRACT_RC fences=$DOC_FMT_N bad=$DOC_FMT_BAD" \
      "extract=0 fences=$DOC_FMT_N bad=0"

check "single changelog fragment names all fixed issues" \
      "$(find "$TESTS_DIR/../changes/fixed" -maxdepth 1 -type f \( -name '*1245*' -o -name '*1246*' -o -name '*1581*' \) | wc -l | tr -d ' ')|$(cat "$TESTS_DIR/../changes/fixed/1581-cloud-fix.md")" \
      "1|- Fixed formatter literal preservation and lexer-owned indentation handling (#1245, #1246, #1581)."

# The unit cases above cover the operators we know about; this covers the ones
# we don't. A character-level formatter regenerates this bug class easily, so
# the standing assertion is behavioural, not case-by-case: every .eigs in the
# repo that parses before --fmt must still parse after it. This one check
# catches all 28 files the +=/<</>>/=>/|> splitting broke.
# Gated on the A/B — files that do not parse to begin with (examples/errors/)
# are excluded, so a pre-existing parse error can never mask a formatter bug.
CORPUS_BROKEN=""
CORPUS_N=0 CORPUS_UNCHANGED=0 CORPUS_CHANGED=0 CORPUS_REFUSED=0
FMT_TMP=$(mktemp /tmp/fmt_corpus_XXXXXX.eigs)
FMT_TWICE=$(mktemp /tmp/fmt_corpus_twice_XXXXXX.eigs)
for f in "$TESTS_DIR"/../examples/*.eigs "$TESTS_DIR"/../lib/*.eigs "$TESTS_DIR"/*.eigs; do
    [ -f "$f" ] || continue
    $EIGS --lint --lint-level error "$f" >/dev/null 2>&1 || continue
    CORPUS_N=$((CORPUS_N + 1))
    if ! $EIGS --fmt "$f" > "$FMT_TMP" 2>/dev/null; then
        CORPUS_REFUSED=$((CORPUS_REFUSED + 1))
        CORPUS_BROKEN="$CORPUS_BROKEN $(basename "$f"):formatter-refused"
        continue
    fi
    if cmp -s "$f" "$FMT_TMP"; then CORPUS_UNCHANGED=$((CORPUS_UNCHANGED + 1));
    else CORPUS_CHANGED=$((CORPUS_CHANGED + 1)); fi
    if ! $EIGS --lint --lint-level error "$FMT_TMP" >/dev/null 2>&1; then
        CORPUS_BROKEN="$CORPUS_BROKEN $(basename "$f")"
    fi
    $EIGS --fmt "$FMT_TMP" > "$FMT_TWICE" 2>/dev/null
    cmp -s "$FMT_TMP" "$FMT_TWICE" || CORPUS_BROKEN="$CORPUS_BROKEN $(basename "$f"):not-fixed"
done
rm -f "$FMT_TMP" "$FMT_TWICE"
SEMANTIC_RESULT=$(python3 "$TESTS_DIR/fmt_corpus_semantics.py" "$EIGS" "$TESTS_DIR")
SEMANTIC_RC=$?
[ "$SEMANTIC_RC" -eq 0 ] || CORPUS_BROKEN="$CORPUS_BROKEN semantic:$SEMANTIC_RESULT"
echo "$SEMANTIC_RESULT"
echo "Formatter corpus: examined=$CORPUS_N unchanged=$CORPUS_UNCHANGED changed=$CORPUS_CHANGED refused=$CORPUS_REFUSED (reason: lexer rejection)"
check "--fmt preserves parseability across $CORPUS_N repo files" \
      "broken:$CORPUS_BROKEN" "broken:"

# Black-style safe mode: formatting may change horizontal whitespace and
# comment columns, but never token type/value, physical line, or layout
# structure.  The doc population is exactly the executor's extracted fences.
TOKEN_OUTPUT=$(python3 "$TESTS_DIR/fmt_token_equivalence.py" \
    "$EIGS" "$TESTS_DIR/.." "$DOC_LIST" 2>&1)
TOKEN_RC=$?
printf '%s\n' "$TOKEN_OUTPUT"
check "--fmt preserves token streams across corpus and docs" \
      "rc=$TOKEN_RC failures=$(printf '%s\n' "$TOKEN_OUTPUT" | grep -c '^TOKEN FAIL:' || true)" \
      "rc=0 failures=0"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
[ "$FAIL" -eq 0 ]
