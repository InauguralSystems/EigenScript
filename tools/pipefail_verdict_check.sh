#!/usr/bin/env bash
# Static gate: under `set -o pipefail`, NO PIPELINE MAY DECIDE A VERDICT.
#
# The construct this bans, and why (#1120 named it, #1122 converted the rest):
#
#     if printf '%s' "$s" | grep -q "$pat"; then          # <- banned
#
# `grep -q` exits the instant it matches and closes the read end. The still
# writing `printf` then takes SIGPIPE and exits 141. Under `pipefail` the
# PIPELINE's status is 141 — a FAILED match — while grep's own status was 0,
# MATCHED. The `if` takes the else branch and the test goes red while printing
# the very bytes it says are missing. Measured in #1120: 21 false no-matches in
# 20,000 evaluations on a 157-byte capture, 18 red runs in 186 end-to-end, and
# CERTAIN once the capture exceeds the pipe buffer, because then the writer must
# block and is therefore always still writing when the reader exits.
#
# The rule is about pipelines that decide by STOPPING EARLY, not about grep:
#   * a grep that READS A FILE has no writer to kill                  — allowed
#   * `grep -c`, `grep -v`, `grep -vxF -f` read to EOF                — allowed
#   * `echo "$x" | head -5` printing a diagnostic decides nothing     — allowed
# What is banned is an early-exiting reader at the end of a pipe whose STATUS
# picks a branch: an `if`/`elif`/`while`/`until` condition, or an `&&`/`||` arm.
#
# Replace it with bash's own matcher — no fork, no pipe, no status to misread:
#   str_has      "$s" "$lit"   substring, what `grep -qF` meant
#   str_has_line "$s" "$line"  whole line, what `grep -q "^lit$"` meant
#   str_has_word "$l" "$name"  word in a space list, what `grep -qw` meant
# or `[[ $s =~ $re ]]` when the site really needed a regex.
#
# WHAT THIS GATE DOES NOT COVER (residuals belong in the code, where they
# travel — the header is what the next reader trusts instead of re-deriving):
#   * It is a TEXT SCANNER, not a bash parser. A pipeline assembled at runtime —
#     `eval "$cmd"`, a command held in a variable — is invisible to it.
#   * Subjects are `*.sh` files that set pipefail LEXICALLY. A script that
#     inherits pipefail from its caller, sets it through a variable, or carries
#     no `.sh` extension is not a subject.
#   * Verdict position means an `if`/`elif`/`while`/`until` head or an `&&`/`||`
#     arm. A BARE pipeline whose status becomes a function's return value, or
#     which `set -e` acts on, is NOT flagged. That is deliberate:
#     `tools/strict_differential.sh --selftest` must RUN the banned construct to
#     demonstrate the race, and does so as a bare pipeline. The price is that a
#     real matcher written as the last bare statement of a function slips
#     through — that shape is a review question, not one this gate answers.
#   * Pipes inside `$( )` or backticks are skipped whole: only their TEXT
#     reaches the enclosing test, never their status. `$(cmd | grep -q x; echo
#     $?)` would therefore be missed.
#   * `sed`/`awk` early exit is recognised textually (a `q`/`Q` command, an
#     `exit`). An early exit reached another way — an awk program in a file —
#     is missed.
#   * It does not judge whether a REPLACEMENT is correct. A converted site with
#     a silently WIDER matcher is a review question. What it does pin is that
#     every `str_has*` copy in the tree is byte-identical to the canonical
#     one-liner — which is what makes `tools/strict_differential.sh --selftest`
#     (suite [99s]) load-bearing for all of them: that selftest pins those three
#     matchers' positive AND negative behaviour, and this gate pins that no copy
#     has drifted away from the ones it tested.
#
# Cost: ~1.0 s wall over 18 pipefail scripts / ~5,100 logical lines. Pure bash;
# the scan loop forks nothing.
#
# Usage: tools/pipefail_verdict_check.sh [--selftest]
set -euo pipefail
cd "$(dirname "$0")/.."

# This gate holds itself to its own rule: every match below is bash's, and the
# files are read with `while read` and `<`, never through a pipe.
str_has() { case "$1" in *"$2"*) return 0 ;; esac; return 1 ; }

# ---- vacuity floors -------------------------------------------------------
# A check that examined nothing is a FAILURE, not a pass. All three floors are
# well under the current tree (18 pipefail scripts, ~5,100 logical lines, 11
# matcher copies) and are here to catch the enumeration COLLAPSING — a
# `git ls-files` that returns nothing, a cd to the wrong place, a scanner that
# reads zero lines. They are floors, not pins (mechanical-gates §5): a script
# that legitimately stops setting pipefail lowers the count and needs no edit.
MIN_PIPEFAIL_SCRIPTS=10
MIN_LOGICAL_LINES=500
MIN_MATCHER_DEFS=8

# ---- what counts as a reader that stops early -----------------------------
# grep with -q/-l/-L/-m (in any short bundle, or the long spellings), head,
# `sed` with a `q`/`Q` command, `awk` with an `exit`, and the `read` builtin.
# The short-option form is anchored to a WHOLE token so `--line-number` is not
# read as `-l` and `-vxF` is not read as anything. A leading `!` and any number
# of VAR=value prefixes are stepped over first, so `| LC_ALL=C grep -q` is seen.
READER_RE='^[[:space:]]*(!?[[:space:]]*)([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*((grep|egrep|fgrep)([[:space:]]|$)|head([[:space:]]|$)|sed([[:space:]]|$)|awk([[:space:]]|$)|read([[:space:]]|$))'
GREP_EARLY_RE='(^|[[:space:]])(-[A-Za-z]*[qlLm][A-Za-z0-9]*|--quiet|--silent|--max-count|--files-with-matches|--files-without-match)([[:space:]=]|$)'
SED_EARLY_RE='(^|[[:space:];{"'"'"'])[[:digit:]]*[qQ]([[:space:];}"'"'"']|$)'
AWK_EARLY_RE='(^|[[:space:];{"'"'"'])exit([[:space:];})"'"'"']|$)'

# ---- subject enumeration --------------------------------------------------
# git where possible, `find` as the fallback: --selftest builds its fault trees
# outside a repository, where `git ls-files` returns nothing, and a gate that
# silently examines zero files there would be the exact hole it exists to close.
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

# A subject is a script that ENABLES pipefail lexically: a non-comment line
# carrying both "set -" and "pipefail" (`set -o pipefail`, `set -euo pipefail`).
# `set +o pipefail` carries "set +" and is therefore not a subject, which is
# right — it turns the option OFF.
sets_pipefail() {   # <file>
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        case "${line#"${line%%[![:space:]]*}"}" in '#'*) continue ;; esac
        if str_has "$line" "pipefail" && str_has "$line" "set -"; then return 0; fi
    done < "$1"
    return 1
}

# Pipes inside `$( )` or backticks are NOT verdicts: only the substitution's
# TEXT reaches the enclosing test, never the pipeline's status, so pipefail
# cannot flip a branch through one. `echo "$(printf %s "$o" | head -1)"` is a
# diagnostic no matter what surrounds it. Strip those bodies before splitting,
# or every line that merely CONTAINS a substitution reads as a verdict site.
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

# Does this pipeline segment end in a reader that stops early?
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

        # Verdict position? A condition head, or an && / || arm.
        pos=""
        case "$lead" in
            if\ *|if\(*|elif\ *|while\ *|until\ *) pos="cond" ;;
        esac
        if [ -z "$pos" ] && { str_has "$lead" "&&" || str_has "$lead" "||"; }; then pos="conn"; fi
        [ -z "$pos" ] && continue

        # Split on REAL pipes: protect `||` first so it is not read as a pipe.
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

# ---- the matchers must not drift ------------------------------------------
# Eight files carry their own copy of these one-liners — the six #1122 scripts,
# tools/strict_differential.sh, and this gate (a sourced helper would need path
# resolution before each script's own `cd`, which is its own footgun). A copy
# that drifts WIDER is the failure this whole conversion exists to prevent, so
# every copy is pinned to the byte.
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
            # Column alignment differs where the three are declared together
            # (`str_has()      {`); the canonical forms contain no run of two
            # spaces, so squeezing runs to one normalises alignment and nothing
            # else. What must not drift is the BODY.
            while str_has "$trimmed" "  "; do trimmed="${trimmed//  / }"; done
            MATCHER_DEFS=$((MATCHER_DEFS + 1))
            if [ "$trimmed" != "$want" ]; then
                MATCHER_BAD="$MATCHER_BAD  $f: $trimmed"$'\n'"    want: $want"$'\n'
            fi
        done < "$f"
    done <<<"$(list_scripts)"
}

# ---- selftest -------------------------------------------------------------
# What this proves: the detector FIRES on the banned construct in each of its
# spellings, and STAYS QUIET on the legitimate ones. Without the negative half
# a detector that flags everything would pass; without the positive half one
# that flags nothing would.
if [ "${1:-}" = "--selftest" ]; then
    echo "== pipefail_verdict_check selftest =="
    st_n=0; st_fail=0
    TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
    # The fixtures below spell their pipes `@PIPE@`, expanded here. This file
    # is scanned by this gate like any other pipefail script, so writing the
    # banned construct literally in a fixture would make the auditor flag its
    # own test data — and a self-exemption is how an auditor goes blind. The
    # substitution keeps the fixtures readable and keeps this file provably
    # free of the construct in every position.
    probe() {   # <want: FIRE|QUIET> <label> <script body, pipes as @PIPE@>
        local want="$1" label="$2" body="${3//@PIPE@/|}"
        printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$body" > "$TD/p.sh"
        HITS=0; HIT_LIST=""; LINES_SCANNED=0
        scan_file "$TD/p.sh"
        st_n=$((st_n + 1))
        local got="QUIET"; [ "$HITS" -gt 0 ] && got="FIRE"
        if [ "$got" = "$want" ]; then printf '  ok    %-6s %s\n' "$want" "$label"
        else st_fail=$((st_fail + 1)); printf '  FAIL  want %s got %s: %s\n' "$want" "$got" "$label"; fi
    }

    # --- must FIRE: the banned construct, every spelling that decides ---
    probe FIRE  'if <pipe into grep -q>'          'if printf "%s" "$s" @PIPE@ grep -q "x"; then :; fi'
    probe FIRE  'if ! <pipe into grep -q>'        'if ! echo "$s" @PIPE@ grep -q "x"; then :; fi'
    probe FIRE  'if [ .. ] && <pipe into grep -q>' 'if [ "$a" = 1 ] && printf "%s" "$s" @PIPE@ grep -q "x"; then :; fi'
    probe FIRE  '|| <pipe into grep -q> && return' 'f() { printf "%s" "$1" @PIPE@ grep -qE "re" && return 0; }'
    probe FIRE  'grep -qF'                        'if echo "$s" @PIPE@ grep -qF "x"; then :; fi'
    probe FIRE  'grep -qx / -qw'                  'if echo "$s" @PIPE@ grep -qxF "x"; then :; fi'
    probe FIRE  'grep --quiet long form'          'if echo "$s" @PIPE@ grep --quiet "x"; then :; fi'
    probe FIRE  'grep -l'                         'if echo "$s" @PIPE@ grep -l "x"; then :; fi'
    probe FIRE  'grep -m1'                        'if echo "$s" @PIPE@ grep -m1 "x" >/dev/null; then :; fi'
    probe FIRE  'pipe into head in a condition'   'if echo "$s" @PIPE@ head -1 >/dev/null; then :; fi'
    probe FIRE  'pipe into sed q'                 'if echo "$s" @PIPE@ sed -n "1p;q" >/dev/null; then :; fi'
    probe FIRE  'pipe into awk exit'              'if echo "$s" @PIPE@ awk "/x/ { exit 0 }"; then :; fi'
    probe FIRE  'pipe into read'                  'if echo "$s" @PIPE@ read -r line; then :; fi'
    probe FIRE  'backslash-continued condition'   'if [ "$a" = 1 ] \
   && printf "%s" "$s" @PIPE@ grep -q "x"; then :; fi'
    probe FIRE  'while condition'                 'while echo "$s" @PIPE@ grep -q "x"; do break; done'
    probe FIRE  'env prefix before the reader'    'if echo "$s" @PIPE@ LC_ALL=C grep -q "x"; then :; fi'

    # --- must stay QUIET: the legitimate greps ---
    probe QUIET 'grep -q reading a FILE'          'if grep -q "x" eigs.json; then :; fi'
    probe QUIET 'grep -q FILE on an || arm'       '[ -f f ] || grep -q "x" f'
    probe QUIET 'grep -c reads to EOF'            'if [ "$(printf "%s" "$s" @PIPE@ grep -c "^OK")" -gt 0 ]; then :; fi'
    probe QUIET 'grep -vxF -f reads to EOF'       'x=$(printf "%s\n" "$a" @PIPE@ grep -vxF -f <(printf "%s\n" "$b") || true); [ -n "$x" ] && echo hi'
    probe QUIET 'grep -v | tail diagnostic'         'printf "%s\n" "$g" @PIPE@ grep -v "x" @PIPE@ tail -5'
    probe QUIET 'head as a bare diagnostic'       'echo "$OUT" @PIPE@ head -5'
    probe QUIET 'head inside a printf argument'   'printf "%s\n" "$(printf "%s" "$out" @PIPE@ head -1)" && echo done'
    probe QUIET 'a comment naming the construct'  '# if printf "%s" "$s" @PIPE@ grep -q "x"; then'
    probe QUIET 'grep --line-number is not -l'    'if echo "$s" @PIPE@ grep --line-number "x" >/dev/null; then :; fi
true'
    probe QUIET 'pipe into head inside $( ) in a test' 'if [ -n "$(printf "%s" "$s" @PIPE@ head -1)" ]; then :; fi'
    probe QUIET 'pipe into grep -q inside a backtick'  'x=`printf "%s" "$s" @PIPE@ head -1` && echo "$x"'
    probe FIRE  '$( ) elsewhere must not blind it'     'if [ "$(id -u)" = 0 ] && printf "%s" "$s" @PIPE@ grep -q "x"; then :; fi'
    probe QUIET 'sort/uniq read to EOF'           'if [ -n "$(printf "%s\n" "$s" @PIPE@ sort -u)" ]; then :; fi'
    probe QUIET 'tail reads to EOF'               'if [ -n "$(printf "%s\n" "$s" @PIPE@ tail -1)" ]; then :; fi'

    # --- the subject filter itself ---
    printf '#!/usr/bin/env bash\nset -e\nif echo "$s" | grep -q x; then :; fi\n' > "$TD/nopf.sh"
    st_n=$((st_n + 1))
    if sets_pipefail "$TD/nopf.sh"; then
        st_fail=$((st_fail + 1)); echo "  FAIL  a script without pipefail was treated as a subject"
    else echo "  ok    QUIET  a script that does not set pipefail is not a subject"; fi
    printf '#!/usr/bin/env bash\nset -euo pipefail\n' > "$TD/pf.sh"
    st_n=$((st_n + 1))
    if sets_pipefail "$TD/pf.sh"; then echo "  ok    FIRE   \`set -euo pipefail\` is recognised as a subject"
    else st_fail=$((st_fail + 1)); echo "  FAIL  \`set -euo pipefail\` was not recognised"; fi
    printf '#!/usr/bin/env bash\nset +o pipefail\n' > "$TD/offpf.sh"
    st_n=$((st_n + 1))
    if sets_pipefail "$TD/offpf.sh"; then
        st_fail=$((st_fail + 1)); echo "  FAIL  \`set +o pipefail\` (which DISABLES it) was read as a subject"
    else echo "  ok    QUIET  \`set +o pipefail\` disables the option and is not a subject"; fi

    # --- the matcher-drift check must be able to fail ---
    printf '#!/usr/bin/env bash\nstr_has() { case "$1" in "$2"*) return 0 ;; esac; return 1 ; }\n' > "$TD/drift.sh"
    MATCHER_DEFS=0; MATCHER_BAD=""
    while IFS= read -r line || [ -n "$line" ]; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        while str_has "$trimmed" "  "; do trimmed="${trimmed//  / }"; done
        case "$trimmed" in 'str_has()'*) MATCHER_DEFS=$((MATCHER_DEFS+1));
            [ "$trimmed" != "$CANON_str_has" ] && MATCHER_BAD="drift" ;; esac
    done < "$TD/drift.sh"
    st_n=$((st_n + 1))
    if [ -n "$MATCHER_BAD" ]; then echo "  ok    FIRE   a prefix-only str_has is caught as drift"
    else st_fail=$((st_fail + 1)); echo "  FAIL  a drifted str_has was accepted"; fi

    # --- vacuity: the selftest itself must have measured something ---
    if [ "$st_n" -lt 34 ]; then
        echo "  VACUOUS: only $st_n checks ran — the selftest itself broke"
        st_fail=$((st_fail + 1))
    fi
    echo "  checks=$st_n failed=$st_fail"
    [ "$st_fail" = 0 ] && { echo "OK"; exit 0; }
    echo "FAIL"; exit 1
fi

# ---- the gate -------------------------------------------------------------
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
