#!/bin/bash
# Test the EigenScript formatter (--fmt)
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="$TESTS_DIR/../src/eigenscript"

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

# --- Trailing whitespace removal ---
ACTUAL=$(fmt_str "$(printf 'x is 42   \ny is 10  \n')")
EXPECTED=$(printf 'x is 42\ny is 10\n')
check "trailing whitespace removal" "$ACTUAL" "$EXPECTED"

# --- Collapse multiple blank lines ---
ACTUAL=$(fmt_str "$(printf 'x is 1\n\n\n\ny is 2\n')")
EXPECTED=$(printf 'x is 1\n\ny is 2\n')
check "collapse multiple blank lines" "$ACTUAL" "$EXPECTED"

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

# --- Idempotency on clean file ---
ORIGINAL=$($EIGS --fmt examples/hello.eigs 2>/dev/null)
TMPF=$(mktemp /tmp/fmt_test_XXXXXX.eigs)
printf '%s' "$ORIGINAL" > "$TMPF"
DOUBLE=$($EIGS --fmt "$TMPF" 2>/dev/null)
rm -f "$TMPF"
check "idempotent on hello.eigs" "$DOUBLE" "$ORIGINAL"

# --- Blank line between top-level defines ---
ACTUAL=$(fmt_str "$(printf 'define foo() as:\n    return 1\ndefine bar() as:\n    return 2\n')")
EXPECTED=$(printf 'define foo() as:\n    return 1\n\ndefine bar() as:\n    return 2\n')
check "blank line between defines" "$ACTUAL" "$EXPECTED"

# --- Write mode ---
TMPFILE=$(mktemp /tmp/fmt_test_XXXXXX.eigs)
printf 'x is 1+2\n' > "$TMPFILE"
$EIGS --fmt --write "$TMPFILE" 2>/dev/null
ACTUAL=$(cat "$TMPFILE")
EXPECTED=$(printf 'x is 1 + 2\n')
check "--write mode" "$ACTUAL" "$EXPECTED"
rm -f "$TMPFILE"

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

# --- Corpus property: formatting a valid program must leave it valid (#729) ---
# The unit cases above cover the operators we know about; this covers the ones
# we don't. A character-level formatter regenerates this bug class easily, so
# the standing assertion is behavioural, not case-by-case: every .eigs in the
# repo that parses before --fmt must still parse after it. This one check
# catches all 28 files the +=/<</>>/=>/|> splitting broke.
# Gated on the A/B — files that do not parse to begin with (examples/errors/)
# are excluded, so a pre-existing parse error can never mask a formatter bug.
CORPUS_BROKEN=""
CORPUS_N=0
FMT_TMP=$(mktemp /tmp/fmt_corpus_XXXXXX.eigs)
for f in "$TESTS_DIR"/../examples/*.eigs "$TESTS_DIR"/../lib/*.eigs "$TESTS_DIR"/*.eigs; do
    [ -f "$f" ] || continue
    $EIGS --lint --lint-level error "$f" >/dev/null 2>&1 || continue
    CORPUS_N=$((CORPUS_N + 1))
    $EIGS --fmt "$f" > "$FMT_TMP" 2>/dev/null
    if ! $EIGS --lint --lint-level error "$FMT_TMP" >/dev/null 2>&1; then
        CORPUS_BROKEN="$CORPUS_BROKEN $(basename "$f")"
    fi
done
rm -f "$FMT_TMP"
check "--fmt preserves parseability across $CORPUS_N repo files" \
      "broken:$CORPUS_BROKEN" "broken:"

echo ""
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
[ "$FAIL" -eq 0 ]
