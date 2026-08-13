#!/bin/bash
# Assert src/fmt.c's MULTI_OPS covers every multi-char operator src/lexer.c
# accepts (#750, follow-up to #729).
#
# WHY THIS EXISTS. fmt.c's third spacing pass scans RAW CHARACTERS, not tokens.
# An operator the lexer accepts but MULTI_OPS omits falls through to the
# single-char branches, which insert a space INSIDE it — `a >>= b` becomes
# `a >> = b` — and `--fmt --write` then corrupts the file on disk. That is
# exactly how #729 happened.
#
# #729 fixed the instance (MULTI_OPS was completed and matched longest-first)
# and added a corpus gate: every .eigs in the repo that parses before --fmt must
# still parse after. But that gate is blind precisely when it matters — a NEWLY
# added operator typically has no in-repo user yet, so no corpus file exercises
# it, and the two tables drift apart silently until someone writes the first
# program using it. Keeping them in sync was left to convention, and convention
# is what failed the first time.
#
# So this compares the two tables directly, deriving the lexer's set from the
# lexer rather than from a second hand-written list — a third list would just be
# a third thing to drift.
#
# Usage: tools/fmt_operator_sync_check.sh [--selftest]
#   --selftest : plant a lexer operator that MULTI_OPS lacks and confirm the
#                comparison FAILS, then confirm the clean tree passes — proves
#                the checker is not vacuously green.
# Exit 0 = every lexer multi-char operator is present in MULTI_OPS.

set -u
cd "$(dirname "$0")/.." || exit 1

# Resolved inside the extractors, not once at startup: the selftest overrides
# LEXER_SRC/FMT_SRC per call, and a startup-time capture would ignore it — the
# selftest would then silently re-check the real tree and pass vacuously.

# Derive the lexer's multi-char operator set from its symbol switch.
#
# The lexer spells every multi-char operator as a lookahead chain inside a
# `case 'X':` block: a lookahead at p+1 for a 2-char operator, plus one at p+2
# on the same line for a 3-char one.
#
# The lookahead is NORMALISED before matching, because keying on one literal
# spelling made the gate depend on a coding STYLE and it silently missed every
# variant of the same code. All of these are now one canonical form:
#   *(p+1) == 'x'      p[1] == 'x'      *(p + 1) == 'x'      *(p+1)=='x'
# and 3-char chains may MIX the two spellings (`*(p+1) == '<' && p[2] == '<'`),
# which an alternation of two fixed patterns could not see. Whitespace is
# stripped and `*(p+N)`/`p[N]` collapse to `LN` first, so spacing and mixing
# stop mattering. Scanning is bounded to the switch body (`switch (*p) {` ..
# `default:`) so unrelated lookahead elsewhere in the file cannot leak in.
#
# RESIDUAL, stated precisely because an earlier version of this comment
# overclaimed. This reads the lexer's SOURCE. Normalisation covers pointer-vs-
# index spelling, internal whitespace, and mixed 3-char chains — verified by
# planting each. It does NOT cover a structurally different implementation: a
# lookup table, a helper call, `memcmp`, or a lookahead through a variable other
# than `p`. For such an operator the extracted set is unchanged, so EXPECTED_OPS
# does NOT catch it either — EXPECTED_OPS only fires when the count MOVES, which
# makes it a backstop against the extractor silently losing an operator it used
# to see, NOT against one it never saw. The only complete fix is a behavioral
# probe asking the built binary which byte pairs lex as a single token; `--fmt`
# is line-based and never parses, so there is no parse-error signal to key on
# and each operator class needs its own valid context. Filed as follow-up on
# #750. Until then #729'"'"'s corpus gate is the backstop, and it only bites once
# some .eigs in the repo actually uses the operator.
# Portability note: no 3-argument match(), no gensub, no \+ in a regex — this
# runs on macOS CI, where awk is BSD awk, not gawk. The lookahead lines are
# reduced to marker lines with sed first, so awk only has to carry the enclosing
# case character forward.
extract_lexer_ops() {
    local lexer="${LEXER_SRC:-src/lexer.c}"
    sed -n '/switch (\*p) {/,/^[[:space:]]*default:/p' "$lexer" \
    | sed -e "s/.*case '\(.\)':.*/CASE \1/" \
          -e '/^CASE /!s/[[:space:]]//g' \
          -e '/^CASE /!s/\*(p+1)/L1/g' -e '/^CASE /!s/p\[1\]/L1/g' \
          -e '/^CASE /!s/\*(p+2)/L2/g' -e '/^CASE /!s/p\[2\]/L2/g' \
          -e "s/.*L1=='\(.\)'&&L2=='\(.\)'.*/OP2 \1 \2/" \
          -e "s/.*L1=='\(.\)'.*/OP1 \1/" \
    | awk '
        $1 == "CASE" { c = $2; next }
        c == ""      { next }
        $1 == "OP2"  { print c $2 $3; next }
        $1 == "OP1"  { print c $2 }
      ' \
    | sort -u
}

# Pull the string literals out of fmt.c's MULTI_OPS initializer.
extract_fmt_ops() {
    local fmt="${FMT_SRC:-src/fmt.c}"
    sed -n '/static const char \*const MULTI_OPS\[\] = {/,/};/p' "$fmt" \
    | grep -o '"[^"]*"' \
    | tr -d '"' \
    | sort -u
}

# Interim backstop for the residual above: the number of operators the scan is
# expected to find. Bump deliberately when an operator is added or removed.
EXPECTED_OPS="${EXPECTED_OPS_OVERRIDE:-18}"

compare_tables() {
    local lex fmt missing extra n_lex
    lex=$(extract_lexer_ops)
    fmt=$(extract_fmt_ops)

    if [ -z "$lex" ]; then
        echo "GATE ERROR: extracted no operators from ${LEXER_SRC:-src/lexer.c} — the matcher broke;"
        echo "this check would pass forever. Fix the extractor, do not delete the gate."
        return 1
    fi
    if [ -z "$fmt" ]; then
        echo "GATE ERROR: extracted no operators from ${FMT_SRC:-src/fmt.c}'s MULTI_OPS — the matcher broke."
        return 1
    fi

    missing=$(comm -23 <(printf '%s\n' "$lex") <(printf '%s\n' "$fmt"))
    extra=$(comm -13 <(printf '%s\n' "$lex") <(printf '%s\n' "$fmt"))

    if [ -n "$missing" ]; then
        echo "FAIL: the lexer accepts multi-char operator(s) that fmt.c's MULTI_OPS omits:"
        printf '%s\n' "$missing" | sed 's/^/    /'
        echo ""
        echo "fmt.c's spacing pass is character-level, so each of these will be split by"
        echo "the single-char branches — 'a $(printf '%s' "$missing" | head -1) b' formats to a corrupted program, and"
        echo "--fmt --write corrupts the file on disk. Add them to MULTI_OPS in src/fmt.c,"
        echo "keeping the table ordered longest-first."
        return 1
    fi

    if [ -n "$extra" ]; then
        echo "NOTE: MULTI_OPS lists operator(s) the lexer no longer accepts:"
        printf '%s\n' "$extra" | sed 's/^/    /'
        echo "(harmless for correctness — longest-first matching just never fires — but stale.)"
    fi

    # Count backstop LAST: a concrete "operator X is missing from MULTI_OPS" is
    # strictly more actionable, so it wins when both would fire. This one only
    # speaks when the sets agree yet the size moved — i.e. the extractor itself
    # started under- or over-reporting.
    n_lex=$(printf '%s\n' "$lex" | grep -c .)
    if [ "$n_lex" -ne "$EXPECTED_OPS" ]; then
        echo "FAIL: extracted $n_lex lexer operators, expected $EXPECTED_OPS."
        echo "The two tables AGREE, so this is the extractor changing what it sees:"
        echo "either an operator was added/removed (bump EXPECTED_OPS and update"
        echo "MULTI_OPS), or a lexer spelling stopped being recognised. Extracted:"
        printf '%s\n' "$lex" | sed 's/^/    /'
        return 1
    fi

    echo "PASS: all $(printf '%s\n' "$lex" | grep -c .) lexer multi-char operators are covered by MULTI_OPS"
    return 0
}

if [ "${1:-}" = "--selftest" ]; then
    st_fail=0
    work=$(mktemp -d /tmp/eigs_fmt_op_sync_XXXXXX)
    trap 'rm -rf -- "$work"' EXIT

    # The real tables must agree.
    if ! compare_tables >/dev/null 2>&1; then
        echo "SELFTEST FAILED: the real tree does not pass its own check"
        st_fail=1
    fi

    # Plant #729's exact shape: a new lexer operator with no MULTI_OPS entry.
    # `@=` is not a real EigenScript operator, which is the point — a brand-new
    # operator is precisely the case the #729 corpus gate cannot see, because no
    # .eigs file uses it yet.
        awk '
        /case '\''~'\'':/ && !done {
            print "            case '\''@'\'':"
            print "                if (*(p+1) == '\''='\'') { tok_add(&tl, TOK_AT_EQ, 0, NULL, line, tok_col); p += 2; col += 2; }"
            print "                else { tok_add(&tl, TOK_AT, 0, NULL, line, tok_col); p++; col++; }"
            print "                break;"
            done = 1
        }
        { print }
    ' "src/lexer.c" > "$work/lexer_planted.c"

    if ! grep -q "case '@':" "$work/lexer_planted.c"; then
        echo "SELFTEST FAILED: could not plant the new-operator fault"
        st_fail=1
    elif LEXER_SRC="$work/lexer_planted.c" compare_tables >/dev/null 2>&1; then
        echo "SELFTEST FAILED: a lexer operator absent from MULTI_OPS was not caught"
        st_fail=1
    fi

    # A 3-char planted operator must also be caught, not just a 2-char one.
    awk '
        /case '\''~'\'':/ && !done {
            print "            case '\''@'\'':"
            print "                if (*(p+1) == '\''@'\'' && *(p+2) == '\''='\'') { tok_add(&tl, TOK_AT2_EQ, 0, NULL, line, tok_col); p += 3; col += 3; }"
            print "                else { tok_add(&tl, TOK_AT, 0, NULL, line, tok_col); p++; col++; }"
            print "                break;"
            done = 1
        }
        { print }
    ' "src/lexer.c" > "$work/lexer_planted3.c"
    if LEXER_SRC="$work/lexer_planted3.c" compare_tables >/dev/null 2>&1; then
        echo "SELFTEST FAILED: a 3-char lexer operator absent from MULTI_OPS was not caught"
        st_fail=1
    fi

    # Spelling variants. Each of these was a SILENT PASS before normalisation —
    # the gate reported "all 18 covered" and the count did not move, so the miss
    # looked exactly like coverage. Mixed 3-char chains are the subtle one: an
    # alternation of two fixed patterns cannot see `*(p+1) ... && p[2] ...`.
    st_plant_cond() {  # $1 = the if-condition text; writes $work/lx.c
        awk -v cond="$1" '
            /case .~.:/ && !d {
                print "            case '"'"'@'"'"':"
                print "                if (" cond ") { tok_add(&tl, TOK_X, 0, NULL, line, tok_col); p += 2; col += 2; }"
                print "                else { tok_add(&tl, TOK_AT, 0, NULL, line, tok_col); p++; col++; }"
                print "                break;"
                d = 1
            }
            { print }
        ' "${LEXER_SRC:-src/lexer.c}" > "$work/lx.c"
    }
    for st_cond in \
        "*(p+1) == 'x'" \
        "p[1] == 'x'" \
        "*(p+1)=='x'" \
        "*(p + 1) == 'x'" \
        "p[1]=='x'" \
        "*(p+1) == 'x' && *(p+2) == 'y'" \
        "p[1] == 'x' && p[2] == 'y'" \
        "*(p+1) == 'x' && p[2] == 'y'" \
        "p[1] == 'x' && *(p+2) == 'y'"
    do
        st_plant_cond "$st_cond"
        if LEXER_SRC="$work/lx.c" compare_tables >/dev/null 2>&1; then
            echo "SELFTEST FAILED: a planted operator spelled \`$st_cond\` was not caught"
            st_fail=1
        fi
    done

    # An empty extraction must be a hard failure, never a silent pass.
    : > "$work/empty.c"
    if LEXER_SRC="$work/empty.c" compare_tables >/dev/null 2>&1; then
        echo "SELFTEST FAILED: an empty lexer extraction passed"
        st_fail=1
    fi
    if FMT_SRC="$work/empty.c" compare_tables >/dev/null 2>&1; then
        echo "SELFTEST FAILED: an empty MULTI_OPS extraction passed"
        st_fail=1
    fi

    if [ "$st_fail" -ne 0 ]; then
        exit 1
    fi
    echo "SELFTEST OK: planted operators caught in all 9 lookahead spellings (pointer/index, spaced/unspaced, 2-char/3-char, and mixed chains), empty extractions hard-fail, clean tree passes"
    exit 0
fi

compare_tables
