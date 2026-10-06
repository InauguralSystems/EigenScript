#!/usr/bin/env bash
# num_read_check.sh -- #1637 round 4: raw number reads are TOKENS, and every
# token is reviewed.
#
# The Value union's number member is `num_` and the EigsSlot union's double is
# `d_`, so no unreviewed spelling compiles. Code reaches a number in exactly
# two ways:
#   - the checking accessors eigs_num_arg / eigs_list_num / eigs_opt_num,
#     which raise a type error on a bool or any other non-number;
#   - the raw macros VAL_NUM_RAW(v) / SLOT_NUM_RAW(s) (and VAL_NUM_OFFSET for
#     JIT-emitted loads), for a value whose type is already proven.
# This gate enumerates every raw token in src/*.c and src/*.h. It attributes
# each one to its enclosing function, or to its #define for a macro. Then it
# requires each (file, function) to appear in tools/num_read_allowlist.txt as
# `file|function|count|reason`, with EXACTLY that many tokens. So a new raw
# read -- a soft default split over any number of lines included -- changes
# a count and goes red until someone reviews it.
#
# It also fails on:
#   - `data.num_` / `.d_` spelled out anywhere except the macro definitions
#     (a bypass of the macros);
#   - a bare `->data.builtin(` call: every builtin call must pass the bool
#     gate, eigs_call_builtin;
#   - an allowlist row that is stale, has the wrong count, or has no reason;
#   - zero tokens examined.
# Prints `num-read: examined=N functions=F allowlisted=F violations=0`.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="${NUM_READ_SRC:-$ROOT/src}"
ALLOW="${NUM_READ_ALLOW:-$ROOT/tools/num_read_allowlist.txt}"
[ -f "$ALLOW" ] || { echo "num-read: FAIL: allowlist $ALLOW missing"; exit 1; }
TMP=$(mktemp "${TMPDIR:-/tmp}/num_read.XXXXXX") || exit 2
trap 'rm -f "$TMP" "$TMP.b" "$TMP.c"' EXIT
: > "$TMP.b"

for f in "$SRC_DIR"/*.c "$SRC_DIR"/*.h; do
    [ -f "$f" ] || continue
    awk -v FILE="$(basename "$f")" -v BYPASS="$TMP.b" '
    {
        line = $0
        # strip comments (block comments carry state across lines) and
        # string literals, so prose and messages never count
        if (incmt) { if (index(line, "*/")) { line = substr(line, index(line, "*/") + 2); incmt = 0 } else line = "" }
        gsub(/"([^"\\]|\\.)*"/, "\"\"", line)
        while (match(line, /\/\*([^*]|\*[^\/])*\*\//)) line = substr(line, 1, RSTART - 1) " " substr(line, RSTART + RLENGTH)
        if (index(line, "/*")) { line = substr(line, 1, index(line, "/*") - 1); incmt = 1 }
        sub(/\/\/.*/, "", line)
    }
    # attribution: a #define names its macro (continuations stay with it);
    # a column-0 line with a parameter list that is not a declaration starts
    # a function; a column-0 "}" ends it
    !incont && /^#[ \t]*define[ \t]/ { m = $0; sub(/^#[ \t]*define[ \t]+/, "", m); sub(/[^A-Za-z0-9_].*/, "", m); scope = "#define " m; inmac = 1 }
    !incont && !/^#/ && /^[A-Za-z_][^;]*\(/ && $0 !~ /;[ \t]*$/ && $0 !~ /^(typedef|return|extern)/ {
        fn = $0; sub(/\(.*/, "", fn); n = split(fn, w, /[ *]+/); scope = w[n]; inmac = 0
    }
    { linemac = inmac }
    {
        s = line
        while (match(s, /(VAL_NUM_RAW|SLOT_NUM_RAW)[ \t]*\(|VAL_NUM_OFFSET/)) {
            tok = substr(s, RSTART, RLENGTH); sub(/[ \t]*\($/, "", tok)
            printf "%s|%s|%s|%d\n", FILE, (scope == "" ? "<file scope>" : scope), tok, NR
            s = substr(s, RSTART + RLENGTH)
        }
        if (line ~ /data\.num_|[A-Za-z0-9_)\]]\.d_([^A-Za-z0-9_]|$)/ && scope !~ /^#define (VAL_NUM_RAW|SLOT_NUM_RAW|VAL_NUM_OFFSET)$/)
            printf "%s:%d: %s\n", FILE, NR, $0 >> BYPASS
        if (line ~ /->data\.builtin[ \t]*\(/) printf "%s:%d: ungated builtin call: %s\n", FILE, NR, $0 >> BYPASS
        incont = ($0 ~ /\\$/)
        if (inmac && !incont) { inmac = 0; scope = fnsave }
        if (!inmac) fnsave = scope
    }
    /^}/ && !linemac { scope = ""; fnsave = "" }
    ' "$f"
done > "$TMP"

examined=$(grep -c . "$TMP")
violations=0; stale=0
# per-(file,function) counts, compared both ways with the allowlist
cut -d'|' -f1,2 "$TMP" | sort | uniq -c | awk '{c = $1; $1 = ""; sub(/^ /, ""); print $0 "|" c}' > "$TMP.c"
functions=$(grep -c . "$TMP.c")
while IFS='|' read -r file fn count; do
    row=$(awk -F'|' -v f="$file" -v g="$fn" '$1 == f && $2 == g' "$ALLOW")
    if [ -z "$row" ]; then
        violations=$((violations + 1))
        echo "  VIOLATION: src/$file $fn: $count raw number token(s), function not on the allowlist"
        grep "^$file|$fn|" "$TMP" | awk -F'|' '{printf "      src/%s:%s %s\n", $1, $4, $3}'
        continue
    fi
    want=$(printf '%s\n' "$row" | head -1 | cut -d'|' -f3)
    if [ "$want" != "$count" ]; then
        violations=$((violations + 1))
        echo "  VIOLATION: src/$file $fn: $count raw number token(s), the allowlist reviewed $want"
    fi
done < "$TMP.c"
while IFS='|' read -r file fn count reason; do
    case "$file" in ''|\#*) continue ;; esac
    if [ -z "$reason" ]; then echo "  FAIL: allowlist row without a reason: $file|$fn"; stale=$((stale + 1)); fi
    grep -qF -- "$file|$fn|$count" "$TMP.c" 2>/dev/null ||
        grep -q "^$file|$fn|" "$TMP.c" ||
        { echo "  FAIL: stale allowlist row (no raw token there): $file|$fn"; stale=$((stale + 1)); }
done < "$ALLOW"
bypass=$(grep -c . "$TMP.b")
[ "$bypass" -gt 0 ] && sed 's/^/  VIOLATION: bypass: /' "$TMP.b"
violations=$((violations + bypass))
allowlisted=$(grep -v '^#' "$ALLOW" | grep -c .)
echo "num-read: examined=$examined functions=$functions allowlisted=$allowlisted violations=$violations stale=$stale"
if [ "$examined" -le 0 ] || [ "$violations" -ne 0 ] || [ "$stale" -ne 0 ]; then
    echo "num-read: FAIL"; exit 1
fi
echo "num-read: PASS"
