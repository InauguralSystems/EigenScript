#!/bin/bash
# Under set -o pipefail, no pipeline may decide a verdict (#1122). An early
# reader (grep -q/-l/-m, head, sed q, awk exit, read) makes the writer die
# with SIGPIPE and the pipeline look like a failed match. Subjects are *.sh
# that set pipefail lexically. Examining nothing is a failure, not a pass.
set -euo pipefail
cd "$(dirname "$0")/.."

str_has() { case "$1" in *"$2"*) return 0 ;; esac; return 1 ; }

MIN_PIPEFAIL_SCRIPTS=10
MIN_LOGICAL_LINES=500
MIN_MATCHER_DEFS=8

READER_RE='^[[:space:]]*(!?[[:space:]]*)([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*((grep|egrep|fgrep)([[:space:]]|$)|head([[:space:]]|$)|sed([[:space:]]|$)|awk([[:space:]]|$)|read([[:space:]]|$))'
GREP_EARLY_RE='(^|[[:space:]])(-[A-Za-z]*[qlLm][A-Za-z0-9]*|--quiet|--silent|--max-count|--files-with-matches|--files-without-match)([[:space:]=]|$)'
SED_EARLY_RE='(^|[[:space:];{"'"'"'])[[:digit:]]*[qQ]([[:space:];}"'"'"']|$)'
AWK_EARLY_RE='(^|[[:space:];{"'"'"'])exit([[:space:];})"'"'"']|$)'

list_scripts() {
    local out
    out="$(git ls-files '*.sh' 2>/dev/null || true)"
    if [ -z "$out" ]; then
        out="$(find . -name '*.sh' -not -path './.git/*' 2>/dev/null | sed 's|^\./||' || true)"
    fi
    printf '%s\n' "$out"
}

SCRIPTS_SCANNED=0
LINES_SCANNED=0
HITS=0
HIT_LIST=""

sets_pipefail() {   # <file>
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        case "${line#"${line%%[![:space:]]*}"}" in '#'*) continue ;; esac
        if str_has "$line" "pipefail" && str_has "$line" "set -"; then return 0; fi
    done < "$1"
    return 1
}

STRIPPED=""
strip_subst() {   # <logical line> -> STRIPPED
    local s="$1"
    case "$s" in *'$('*|*'`'*) ;; *) STRIPPED="$s"; return 0 ;; esac
    local out="" i=0 n=${#s} depth=0 c
    while [ "$i" -lt "$n" ]; do
        c="${s:$i:1}"
        if [ "$depth" -gt 0 ]; then
            case "$c" in '(') depth=$((depth + 1)) ;; ')') depth=$((depth - 1)) ;; esac
            i=$((i + 1)); continue
        fi
        if [ "$c" = '$' ] && [ "${s:$((i + 1)):1}" = '(' ]; then depth=1; i=$((i + 2)); continue; fi
        if [ "$c" = '`' ]; then
            i=$((i + 1))
            while [ "$i" -lt "$n" ] && [ "${s:$i:1}" != '`' ]; do i=$((i + 1)); done
            i=$((i + 1)); continue
        fi
        out="$out$c"; i=$((i + 1))
    done
    STRIPPED="$out"
}

early_reader() {   # <segment>
    local seg="$1"
    [[ $seg =~ $READER_RE ]] || return 1
    case "${BASH_REMATCH[0]}" in
        *grep*) [[ $seg =~ $GREP_EARLY_RE ]] || return 1 ;;
        *head*) : ;;
        *sed*)  [[ $seg =~ $SED_EARLY_RE ]] || return 1 ;;
        *awk*)  [[ $seg =~ $AWK_EARLY_RE ]] || return 1 ;;
        *read*) : ;;
        *)      return 1 ;;
    esac
    return 0
}

scan_file() {   # <file>  -> appends to HIT_LIST
    local f="$1" raw ln=0 start=0 logical="" lead seg tmp pos
    local -a segs
    while IFS= read -r raw || [ -n "$raw" ]; do
        ln=$((ln + 1))
        if [ -z "$logical" ]; then start=$ln; fi
        case "$raw" in
            *\\) logical="$logical${raw%\\} "; continue ;;
        esac
        logical="$logical$raw"
        LINES_SCANNED=$((LINES_SCANNED + 1))
        lead="${logical#"${logical%%[![:space:]]*}"}"
        logical=""
        case "$lead" in '#'*|'') continue ;; esac

        pos=""
        case "$lead" in
            if\ *|if\(*|elif\ *|while\ *|until\ *) pos="cond" ;;
        esac
        if [ -z "$pos" ] && { str_has "$lead" "&&" || str_has "$lead" "||"; }; then pos="conn"; fi
        [ -z "$pos" ] && continue

        strip_subst "$lead"
        tmp="${STRIPPED//\|\|/$'\001'}"
        tmp="${tmp//|&/|}"
        IFS='|' read -r -a segs <<<"$tmp"
        [ "${#segs[@]}" -lt 2 ] && continue
        local i
        for ((i = 1; i < ${#segs[@]}; i++)); do
            seg="${segs[$i]//$'\001'/||}"
            if early_reader "$seg"; then
                HITS=$((HITS + 1))
                HIT_LIST="$HIT_LIST$f:$start [$pos] ${lead:0:150}"$'\n'
                break
            fi
        done
    done < "$f"
}

CANON_str_has='str_has() { case "$1" in *"$2"*) return 0 ;; esac; return 1 ; }'
CANON_str_has_line='str_has_line() { case $'"'"'\n'"'"'"$1"$'"'"'\n'"'"' in *$'"'"'\n'"'"'"$2"$'"'"'\n'"'"'*) return 0 ;; esac; return 1 ; }'
CANON_str_has_word='str_has_word() { case " $1 " in *" $2 "*) return 0 ;; esac; return 1 ; }'

MATCHER_DEFS=0
MATCHER_BAD=""
check_matchers() {
    local f line trimmed want
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ -f "$f" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            trimmed="${line#"${line%%[![:space:]]*}"}"
            trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
            case "$trimmed" in
                'str_has()'*)      want="$CANON_str_has" ;;
                'str_has_line()'*) want="$CANON_str_has_line" ;;
                'str_has_word()'*) want="$CANON_str_has_word" ;;
                *) continue ;;
            esac
            while str_has "$trimmed" "  "; do trimmed="${trimmed//  / }"; done
            MATCHER_DEFS=$((MATCHER_DEFS + 1))
            if [ "$trimmed" != "$want" ]; then
                MATCHER_BAD="$MATCHER_BAD  $f: $trimmed"$'\n'"    want: $want"$'\n'
            fi
        done < "$f"
    done <<<"$(list_scripts)"
}

while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    sets_pipefail "$f" || continue
    SCRIPTS_SCANNED=$((SCRIPTS_SCANNED + 1))
    scan_file "$f"
done <<<"$(list_scripts)"

check_matchers

rc=0
if [ "$SCRIPTS_SCANNED" -lt "$MIN_PIPEFAIL_SCRIPTS" ] || [ "$LINES_SCANNED" -lt "$MIN_LOGICAL_LINES" ]; then
    echo "  FAIL: VACUOUS — examined $SCRIPTS_SCANNED pipefail script(s) / $LINES_SCANNED logical line(s);"
    echo "        floors are $MIN_PIPEFAIL_SCRIPTS / $MIN_LOGICAL_LINES. A check that examined nothing is not a pass."
    rc=1
fi
if [ "$MATCHER_DEFS" -lt "$MIN_MATCHER_DEFS" ]; then
    echo "  FAIL: VACUOUS — found only $MATCHER_DEFS str_has* definition(s), floor $MIN_MATCHER_DEFS."
    rc=1
fi
if [ -n "$MATCHER_BAD" ]; then
    echo "  FAIL: a str_has* copy has drifted from the canonical one-liner:"
    printf '%s' "$MATCHER_BAD"
    rc=1
fi
if [ "$HITS" -gt 0 ]; then
    echo "  FAIL: $HITS pipeline(s) decide a verdict under pipefail (#1122):"
    printf '%s' "$HIT_LIST" | sed 's/^/    /'
    echo "        Replace with str_has / str_has_line / str_has_word or [[ \$s =~ re ]]."
    echo "        See the header of this file for why the pipeline is a race."
    rc=1
fi
[ "$rc" = 0 ] && echo "  PASS: no pipeline decides a verdict in $SCRIPTS_SCANNED pipefail script(s) ($LINES_SCANNED logical lines, $MATCHER_DEFS matcher copies pinned)"
exit $rc
