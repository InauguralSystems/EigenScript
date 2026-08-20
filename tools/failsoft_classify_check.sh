#!/usr/bin/env bash
# Every fail-soft return in the builtin surface must be CLASSIFIED (#971).
#
# A builtin that answers a wrong argument with `return make_num(0)` or
# `return make_str("")` turns a mistake into a plausible value: `cos of
# "hello"` was 0, `substr of 42` was "". The #975 fail-soft reform converts
# those to raise under EIGS_STRICT.
#
# But some of these returns are the documented ANSWER — `task_alive` of an
# unknown id is 0, and that `return make_num(0)` sits FOUR LINES from one
# that is a genuine type guard. No pattern separates them; only reading
# does. So this gate decides nothing. It requires that a human decided, by
# demanding a classification marker at every site, and it goes red when an
# unmarked one appears.
#
# Marker: an `fs:TAG` comment on the return line, or anywhere in the
# contiguous comment block immediately above it (a reason worth writing is
# often several lines, and a fixed-size window drops the tag off the top —
# which presents as "you forgot to classify this").
#
#   fs:ANSWER   the 0/"" is the documented result; strict must NOT raise
#   fs:CHANNEL  failure is signalled out-of-band (a flag, an out-param)
#   fs:LITERAL  not a guard — this IS the value being constructed
#   fs:EMPTY    degenerate input with a defined identity (join of [] is "")
#   fs:STRICT   the soft return paired with an `if (g_strict) rt_error` above
#   fs:TODO     deliberately deferred; MUST name an issue (#NNN)
#
# Converted guards use ARG_GUARD() and carry no raw return, so they leave
# this gate's population entirely. The site count FALLING is the progress.
#
# WHAT THIS GATE DOES NOT COVER (every exemption is a waiver, so it is
# written here rather than left to be rediscovered):
#
#   - Soft stand-ins that are not zero/empty: `return make_null()`,
#     `return make_list()`, a sentinel `-1`. Those are a different
#     population and are NOT enumerated here. Counted and reported as a
#     residual by --residuals so the number is visible rather than implied.
#   - A soft return reached through a helper (`return zero_value();`).
#     Nothing in this surface does that today; if one appears, this gate is
#     blind to it by construction — it is a text matcher, not a call graph.
#   - Whether an fs:ANSWER classification is CORRECT. That is what the
#     paired tests in tests/test_strict_math.sh assert; this gate only
#     proves a decision was recorded. A blind review found three sites whose
#     recorded decision was WRONG (sum/mean/norm tagged fs:EMPTY on a line
#     that also carried the non-tensor case) while this gate reported
#     unclassified=0 — so a green here is not evidence the reform is right,
#     only that it is complete.
#   - A MACRO spelling. `#define FAIL_EMPTY return make_str("")` plus
#     `FAIL_EMPTY;` at the use site matches nothing: the define has no `;`
#     and the use site has no `return`. Nothing in the tree does this today.
#     Closing it needs the preprocessor, not a text matcher.
#   - INTERCEPTION, as opposed to removal. FLOOR_SITES catches the count
#     going down; it cannot catch five real sites being neutralised while
#     five tagged decoys are added. The per-tag tally printed below is the
#     only signal there, and nothing gates on it.
#   - A COERCION site, which has no stand-in return to enumerate.
#     `str_replace`/`join`/`write_bytes` silently substituted "" or 0.0 for a
#     wrong-typed element and are invisible here by construction. They are
#     covered instead by STRICT_REQUIRE and by tools/strict_differential.sh,
#     whose population is behavioural rather than syntactic. If you are
#     hunting fail-softness, run BOTH — that is why there are two.
#
# Run: bash tools/failsoft_classify_check.sh [--verbose|--residuals]
#      bash tools/failsoft_classify_check.sh --selftest   (planted faults)

set -uo pipefail

SELF_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

VALID_TAGS='ANSWER|CHANNEL|LITERAL|EMPTY|STRICT|TODO'

# The population floor. Sites leave this population legitimately (a guard
# converted to ARG_GUARD, a builtin deleted), so this is not pinned upward
# — but a DECREASE is a review event, because the other way a site leaves
# is by drifting out of the matcher: reformat `return make_num(0);` across
# two lines and it is neither classified nor counted, and a bidirectional
# check cannot see a loss that removes both of its sides at once (#984's
# lesson). Lower this number only in the same commit that converts the
# guards, and say which ones in the message.
#
# 157 -> 112 on 2026-08-19: 45 guards converted to ARG_GUARD across
# builtins.c, builtins_host.c, builtins_tensor.c and ext_store.c (#971
# Phase B). The 45 are the diff; this number is only the floor under what
# is LEFT.
#
# 112 -> 120 the same day, and NOT because sites were added: fixing the
# builtin-name pattern to allow DIGITS brought src/hash.c into the
# population for the first time (sha256/md5/hmac_sha256 all have one), with
# 8 sites that had never been classified. A floor rising because the
# derivation got wider is the good direction; note it either way.
FLOOR_SITES=120

usage_mode="${1:-}"

# ------------------------------------------------------------------ helpers
#
# The file set is DERIVED, and by two independent routes, because either
# alone has a hole:
#
#   (a) make's own variables — authoritative about what compiles, but no
#       SINGLE variable is enough: SOURCES and FULL_SOURCES do not contain
#       ext_gfx.c at all (only SRC_V_gfx does), and that file holds 33
#       sites. So the union across every SRC_V_* variant is taken.
#   (b) "defines a Value* builtin_...() function" — authoritative about the
#       surface, but blind to a file no variant compiles any more.
#
# Covered set = (b); (b) must be a subset of (a). A builtin-defining file
# outside every variant is reported as an ORPHAN, not silently skipped.
compiled_union() {
    local root="$1" v
    for v in $(grep -oE '^SRC_V_[a-z-]+' "$root/Makefile" | sed 's/^SRC_V_//'); do
        make -C "$root" --eval='__fsp-%: ; @echo $($*)' -s "__fsp-SRC_V_$v" 2>/dev/null
    done | tr ' ' '\n' | sed '/^$/d' | sort -u
}

builtin_files() {
    local root="$1"
    # [a-z_0-9], NOT [a-z_]. Without the digits this missed src/hash.c
    # ENTIRELY — every builtin there has a digit in its name (sha256, md5,
    # hmac_sha256) — and hash.c is in SOURCES, so it compiles into every
    # variant while carrying 8 unclassified fail-soft returns. It was
    # invisible from both ends: not in `covered`, so the ORPHAN check never
    # looked at it either. Found by a blind review with a break-it brief.
    ( cd "$root" && grep -rlE '^[A-Za-z_ ]*Value[ ]*\*[ ]*builtin_[a-z_0-9]+\(' src/*.c 2>/dev/null | sort -u )
}

# A fail-soft return, matched on a whitespace-normalised STATEMENT.
#
# Two independent things make this matcher wider than the one the issue's
# population came from, and both were bought:
#
#   - Normalising whitespace. The narrow `return make_num(0)` spelling missed
#     all ten `make_num(0.0)` sites in builtins_tensor.c — one of which,
#     `if (!a || !b) return make_num(0.0);`, is a textbook null guard. A
#     matcher that under-reports looks exactly like a smaller job.
#   - Joining to the `;`. A line-based matcher cannot see a return split
#     across physical lines, and that is the shape an ordinary reformat
#     produces — the site would leave the population with nothing failing.
#     Statements are joined here rather than detected heuristically, because
#     the heuristic version fired on `vm.c`'s legitimate multi-line
#     `return (uint32_t)ip[0] | ...`, and a gate that cries wolf gets muted.
#
# Emits "startline<TAB>nlines" per matching statement. nlines > 1 means the
# statement is split, which is reported separately: it is matched correctly
# here, but it must be reformatted so the MARKER-context window (the return
# line and the two above it) is meaningful.
norm_hits() {   # <file> -> "startline\tnlines\tctxstart"
    awk '
    # Comments are stripped with real block-comment state AND real STRING
    # state. Two failures bought each half:
    #
    #   - No comment state: the continuation test saw the word "return" in
    #     COMMENT PROSE ("returns 0", "the return value") and opened a pending
    #     statement that swallowed the next line. Five false SPLIT RETURN
    #     reports off this reform own explanatory comments.
    #   - No string state: `strncmp(url, "http://", 7)` has its code truncated
    #     at the // INSIDE the string literal, leaving an unterminated
    #     `returnstrncmp(url,"http:` that opens a pending statement and
    #     swallows the following lines. That desync is live in ext_http.c
    #     right now. A `return make_str("/*");` does the same, permanently,
    #     for every line after it.
    #
    # ctxstart is the first line of the contiguous COMMENT-ONLY run directly
    # above the statement. It is computed here, with the state machine, rather
    # than by walking up for lines starting with "*" — that heuristic credited
    # a marker across a C pointer store (`*ep = 1; /* fs:... */`) to a return
    # several lines below that carried no marker of its own.
    {
        line = $0
        code = ""
        i = 1
        n = length(line)
        while (i <= n) {
            c1 = substr(line, i, 1)
            c2 = substr(line, i, 2)
            if (in_comment) {
                if (c2 == "*/") { in_comment = 0; i += 2 } else { i++ }
            } else if (in_string) {
                if (c1 == "\\") { code = code c2; i += 2; continue }
                if (c1 == "\"") { in_string = 0 }
                code = code c1; i++
            } else if (in_char) {
                if (c1 == "\\") { code = code c2; i += 2; continue }
                if (c1 == "'"'"'") { in_char = 0 }
                code = code c1; i++
            } else if (c2 == "/*") { in_comment = 1; i += 2 }
            else if (c2 == "//") { i = n + 1 }
            else if (c1 == "\"") { in_string = 1; code = code c1; i++ }
            else if (c1 == "'"'"'") { in_char = 1; code = code c1; i++ }
            else { code = code c1; i++ }
        }

        stripped = code; gsub(/[ \t]/, "", stripped)
        # A comment-only line: nothing survived stripping, but the raw line
        # was not blank. Tracked as a run so ctxstart is exact.
        raw = $0; gsub(/[ \t]/, "", raw)
        if (stripped == "" && raw != "") { if (crun_end != NR - 1) crun_start = NR; crun_end = NR }

        if (pending == 0) { start = NR; acc = "" }
        acc = acc code
        sn = acc; gsub(/[ \t]+/, "", sn)

        if (sn ~ /^return/ && index(sn, ";") == 0) { pending = 1; next }
        pending = 0
        if (sn == "") next
        if (sn ~ /returnmake_num\(0(\.0*)?\);/ || sn ~ /returnmake_str\(""\);/) {
            ctx = (crun_end == start - 1) ? crun_start : start
            printf "%d\t%d\t%d\n", start, NR - start + 1, ctx
        }
    }' "$1"
}

# ------------------------------------------------------------------- check
run_check() {   # <root>  -> 0 clean / 1 finding ; prints a summary
    local root="$1"
    local compiled covered f
    compiled="$(compiled_union "$root")"
    covered="$(builtin_files "$root")"

    local n_files=0 n_hits=0 n_bad=0 n_tagged=0 orphan=0 splits=0
    declare -A tally=()
    local c
    for c in $covered; do
        if ! grep -qxF "$c" <<<"$compiled"; then
            echo "  ORPHAN: $c defines builtins but no make variant compiles it"
            orphan=$((orphan + 1))
        fi
    done

    for f in $covered; do
        n_files=$((n_files + 1))
        local ln nl ctx tag
        while read -r ln nl ctxstart; do
            [ -z "$ln" ] && continue
            n_hits=$((n_hits + 1))
            if [ "${nl:-1}" -gt 1 ]; then
                echo "  SPLIT RETURN: $f:$ln spans $nl lines"
                echo "        reformat onto one line — the marker context window"
                echo "        (the return line and the two above it) is otherwise"
                echo "        reading the middle of a statement"
                splits=$((splits + 1))
            fi
            ctx="$(sed -n "${ctxstart},${ln}p" "$root/$f")"
            tag="$(grep -oE "fs:($VALID_TAGS)" <<<"$ctx" | tail -1 | cut -d: -f2)"
            if [ -z "$tag" ]; then
                # A MISSPELLED tag must not read as an honest un-annotated
                # site. Both are findings, but they are different findings,
                # and lumping them lets `fs:ANWSER` hide in the new-work pile.
                if grep -qE 'fs:[A-Za-z]+' <<<"$ctx"; then
                    echo "  BADTAG: $f:$ln — fs: marker with an unrecognised tag"
                else
                    echo "  UNCLASSIFIED: $f:$ln"
                fi
                echo "        $(sed -n "${ln}p" "$root/$f" | sed 's/^[[:space:]]*//')"
                n_bad=$((n_bad + 1))
                continue
            fi
            if [ "$tag" = "TODO" ] && ! grep -qE 'fs:TODO[^*]*#[0-9]+' <<<"$ctx"; then
                echo "  TODO WITHOUT ISSUE: $f:$ln"
                n_bad=$((n_bad + 1))
                continue
            fi
            n_tagged=$((n_tagged + 1))
            tally[$tag]=$(( ${tally[$tag]:-0} + 1 ))
            [ "$usage_mode" = "--verbose" ] && printf '  %-8s %s:%s\n' "$tag" "$f" "$ln"
        done < <(norm_hits "$root/$f")
    done

    # Vacuity. A gate that examined nothing prints OK — the single most
    # dangerous thing a gate can do — so both floors are hard failures.
    local vac=0
    if [ "$n_files" -lt 3 ]; then
        echo "  VACUOUS: examined $n_files builtin files (the derivation broke)"
        vac=1
    fi
    if [ "$n_hits" -lt "$FLOOR_SITES" ]; then
        echo "  BELOW FLOOR: $n_hits sites < FLOOR_SITES=$FLOOR_SITES."
        echo "        Sites leave legitimately when converted to ARG_GUARD —"
        echo "        lower the floor in that same commit. An unexplained drop"
        echo "        means the matcher or the file derivation lost ground."
        vac=1
    fi

    printf '  files=%d sites=%d classified=%d unclassified=%d floor=%d\n' \
        "$n_files" "$n_hits" "$n_tagged" "$n_bad" "$FLOOR_SITES"
    local t out=""
    for t in ANSWER CHANNEL LITERAL EMPTY STRICT TODO; do
        out="$out $t=${tally[$t]:-0}"
    done
    echo " $out"

    [ $(( n_bad + orphan + vac + splits )) -gt 0 ] && return 1
    return 0
}

# --------------------------------------------------------------- residuals
if [ "$usage_mode" = "--residuals" ]; then
    echo "== fail-soft residual population (NOT gated) =="
    for f in $(builtin_files "$SELF_ROOT"); do
        n=$(awk '{s=$0; gsub(/[ \t]+/,"",s); if (s ~ /returnmake_null\(\);/) c++} END{print c+0}' "$SELF_ROOT/$f")
        [ "$n" != 0 ] && printf '  %-26s return make_null(): %s\n' "$f" "$n"
    done
    echo "  (a different soft stand-in; see this script's header)"
    exit 0
fi

# ---------------------------------------------------------------- selftest
if [ "$usage_mode" = "--selftest" ]; then
    echo "== failsoft_classify_check selftest =="
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    # A gate must not mutate what it checks. Every fault below is planted in
    # a COPY, and the copy is keyed to the tree under test — a mutation
    # harness that plants in a copy while the check reads the real tree
    # reports PASS against a build with the mechanism entirely removed.
    root="$tmp/tree"
    mkdir -p "$root/src"
    cp "$SELF_ROOT/Makefile" "$root/Makefile"
    cp "$SELF_ROOT"/src/*.c "$SELF_ROOT"/src/*.h "$root/src/" 2>/dev/null

    before="$(cd "$SELF_ROOT" && cat src/*.c | md5sum)"
    ok=0; bad=0
    expect() {  # <want-rc> <label>
        local want="$1" label="$2" rc
        run_check "$root" >"$tmp/out" 2>&1
        rc=$?
        if [ "$rc" = "$want" ]; then
            echo "  PASS  $label"; ok=$((ok+1))
        else
            echo "  FAIL  $label (rc=$rc want=$want)"; sed 's/^/        /' "$tmp/out"; bad=$((bad+1))
        fi
    }
    restore() { cp "$SELF_ROOT/src/builtins.c" "$root/src/builtins.c"; rm -f "$root/src/builtins_planted.c"; }

    # 0. Control, BOTH halves. A control with only the must-flag half is
    #    satisfied by a check that always fails; and an unstartable mutant
    #    is an invalid probe, not a caught fault — so the clean run must
    #    pass before any planted result is believed.
    expect 0 "control — an unmodified copy classifies clean"
    if [ "$ok" != 1 ]; then
        echo "  BROKEN: the mutant tree does not start clean; later rows prove nothing"
        exit 1
    fi

    # 1. an unmarked fail-soft return
    printf '\nValue* builtin_planted_a(Value *arg) { (void)arg; return make_num(0); }\n' >> "$root/src/builtins.c"
    expect 1 "planted unmarked return is caught"; restore

    # 2. a misspelled tag must not read as classified, and must not read as
    #    an ordinary un-annotated site either
    printf '\nValue* builtin_planted_b(Value *arg) { (void)arg; return make_num(0); /* fs:ANWSER typo */ }\n' >> "$root/src/builtins.c"
    expect 1 "misspelled tag is caught, not silently classified"; restore
    run_check "$root" >/dev/null 2>&1  # (restored)

    # 3. fs:TODO without an issue — otherwise TODO is an unaccountable
    #    escape hatch for the entire gate
    printf '\nValue* builtin_planted_c(Value *arg) { (void)arg; return make_num(0); /* fs:TODO later */ }\n' >> "$root/src/builtins.c"
    expect 1 "fs:TODO without an issue number is caught"; restore

    # 4. the WIDE spelling. The narrow `return make_num(0)` the issue's
    #    population used cannot see this line. If anyone re-narrows the
    #    matcher, this row goes green and tells them.
    printf '\nValue* builtin_planted_d(Value *arg) { (void)arg; return make_num( 0.0 ); }\n' >> "$root/src/builtins.c"
    expect 1 "wide matcher sees the make_num( 0.0 ) spelling"; restore

    # 5. TWO-SIDED LOSS — the case a bidirectional check cannot see. Split
    #    the return across lines AND drop its marker: the site leaves the
    #    population, so "unclassified" stays 0 and only the split detector
    #    and the floor can speak. The one-sided faults above were already
    #    caught by design; a selftest built only from them proves nothing
    #    about this.
    python3 - "$root/src/builtins.c" <<'PY' 2>/dev/null || cp "$SELF_ROOT/src/builtins.c" "$root/src/builtins.c"
import re, sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("        return make_num(0);\n", "        return\n            make_num(0);\n", 1)
open(p, "w").write(s)
PY
    expect 1 "two-sided loss (return split across lines) is caught"; restore

    # 6. a DIGIT in the builtin name must not hide the file. The pattern was
    #    `builtin_[a-z_]+`, which matched nothing in src/hash.c — every
    #    builtin there is sha256/md5/hmac_sha256 — so a compiled file with 8
    #    unclassified sites sat outside the population, invisible to the
    #    ORPHAN check too (it only looks at files already covered).
    cat > "$root/src/builtins_digits.c" <<'EOF'
#include "eigenscript.h"
Value* builtin_sha512(Value *arg) { (void)arg; return make_str(""); }
EOF
    expect 1 "a digit-named builtin file is in the population"; restore

    # 7. a `/*` inside a STRING LITERAL must not open a comment. Without
    #    string state the stripper erases everything after it, permanently,
    #    and the unmarked site below goes unseen. The same desync is live in
    #    ext_http.c via `strncmp(url, "http://", 7)` — the // in the literal.
    printf '\nValue* builtin_planted_str(Value *arg) { (void)arg; return make_str("/*"); }\n' >> "$root/src/builtins.c"
    printf 'Value* builtin_planted_after(Value *arg) { (void)arg; return make_num(0); }\n' >> "$root/src/builtins.c"
    expect 1 "a /* inside a string literal does not blind the scanner"; restore

    # 8. a marker must not be credited to a DIFFERENT site. The context walk
    #    used to accept any line starting with `*` as a comment, so a C
    #    pointer store carrying a trailing tag handed it to a later return.
    cat >> "$root/src/builtins.c" <<'EOF'

Value* builtin_planted_steal(Value *arg, int *ep, int *ep2) {
    (void)arg;
    *ep = 1;   /* fs:CHANNEL a marker on a pointer store, not a comment block */
    *ep2 = 0;
    return make_num(0);
}
EOF
    expect 1 "a marker on a pointer store is not credited to a later return"; restore

    # 9. a builtin-defining file no variant compiles is an ORPHAN
    cat > "$root/src/builtins_planted.c" <<'EOF'
#include "eigenscript.h"
Value* builtin_planted_e(Value *arg) { (void)arg; return make_num(0); /* fs:ANSWER */ }
EOF
    expect 1 "builtin file outside every make variant is an orphan"; restore

    # 7. the leavings. A gate that corrupts the thing it checks manufactures
    #    exactly the defect it exists to detect.
    after="$(cd "$SELF_ROOT" && cat src/*.c | md5sum)"
    if [ "$before" = "$after" ]; then
        echo "  PASS  selftest left the real src/ byte-identical"; ok=$((ok+1))
    else
        echo "  FAIL  selftest MUTATED the real src/"; bad=$((bad+1))
    fi

    echo "  selftest: $ok passed, $bad failed"
    [ "$bad" = 0 ] || exit 1
    exit 0
fi

# -------------------------------------------------------------------- main
echo "== fail-soft classification (#971) =="
if run_check "$SELF_ROOT"; then
    echo "OK"
    exit 0
fi
echo "FAIL: every fail-soft return in the builtin surface must carry an fs:"
echo "      marker. See the header of tools/failsoft_classify_check.sh."
exit 1
