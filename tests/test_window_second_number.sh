#!/usr/bin/env bash
# #2433: a binding's value windows are made at its second number. This replays
# every tape of window_second_number/tapes/ (stepped one stop at a time) and
# runs every program of window_second_number/progs/ (four tiers) on the binary
# under test and compares each output and exit code with
# window_second_number/expect/, written by this file with WSN_RECORD=<dir> from
# a release build of the base (beeb3991 when they were recorded).
# The tapes are remade by window_second_number/regen.sh <eigenscript> <dir>;
# its header says where each tape's window records sit.
# stall1_fin.eigs of the given program set is left out: it loops without end.
set -u
EIGS=${1:-${EIGS:-$(cd "$(dirname "$0")/.." && pwd)/src/eigenscript}}
D="$(cd "$(dirname "$0")" && pwd)/window_second_number"
TMO=${EIGS_TMO:-}
if [ -z "$TMO" ]; then
    if command -v timeout >/dev/null 2>&1; then TMO="timeout 180"
    elif command -v gtimeout >/dev/null 2>&1; then TMO="gtimeout 180"; fi
fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs_wsn.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
REC=${WSN_RECORD:-}
fails=0; tapes=0; runs=0

# check NAME LABEL ACTUAL: compare ACTUAL with expect/NAME, or record it.
check() {
    if [ -n "$REC" ]; then
        if [ -f "$REC/$1" ] && ! cmp -s "$REC/$1" "$3"; then
            fails=$((fails + 1)); echo "FAIL: record: $2 differs from an earlier tier"
        fi
        cp "$3" "$REC/$1"; return 0
    fi
    if [ ! -f "$D/expect/$1" ]; then
        fails=$((fails + 1)); echo "FAIL: $2: no expectation"
    elif cmp -s "$D/expect/$1" "$3"; then
        echo "PASS: $2"
    else
        fails=$((fails + 1)); echo "FAIL: $2: output differs from the base's"
        diff "$D/expect/$1" "$3" | head -8 | sed 's/^/    /'
    fi
}

for t in "$D"/tapes/*.tape; do
    [ -f "$t" ] || continue
    tapes=$((tapes + 1)); b=$(basename "$t" .tape); o="$TMP/$b.tape.out"
    (cd "$D/tapes" && $TMO "$EIGS" --step "$b.tape" < "$D/drive150.in" > "$o" 2>&1; echo "rc=$?" >> "$o")
    stops=$(grep -c '^step ' "$o")
    # The one tape without stream numbers must be refused; every other tape must stop.
    if [ "$b" = const_win_lr_nostream ]; then
        if [ "$stops" -ne 0 ] || ! grep -q 'refusing to step' "$o"; then
            fails=$((fails + 1)); echo "FAIL: $b.tape: not refused (stops=$stops)"; continue
        fi
    elif [ "$stops" -eq 0 ]; then
        fails=$((fails + 1)); echo "FAIL: $b.tape: zero stops"; head -5 "$o" | sed 's/^/    /'; continue
    fi
    check "$b.tape.out" "$b.tape stops=$stops" "$o"
done

progs=0
for p in "$D"/progs/*.eigs; do
    [ -f "$p" ] || continue
    progs=$((progs + 1)); b=$(basename "$p" .eigs)
    for tier in off default osr trace; do
        runs=$((runs + 1)); o="$TMP/$b.$tier.out"; w="$TMP/$b.$tier.d"; mkdir -p "$w"
        case $tier in
            off) te="EIGS_JIT_OFF=1" ;; default) te="" ;;
            osr) te="EIGS_JIT_OSR_THRESHOLD=1" ;; trace) te="EIGS_TRACE=$w/t.tape" ;;
        esac
        (cd "$w" && env -u EIGS_JIT_OFF -u EIGS_JIT_OSR_THRESHOLD -u EIGS_TRACE $te \
            $TMO "$EIGS" "$p" < /dev/null > "$o" 2>&1; echo "rc=$?" >> "$o")
        check "$b.prog.out" "$b.eigs tier=$tier" "$o"
        rm -rf "$w"
    done
done

ntape=$(ls "$D/tapes" | grep -c '\.tape$'); nprog=$(ls "$D/progs" | grep -c '\.eigs$')
nexp=$(ls "$D/expect" | grep -c '\.out$')
echo "window-second-number: tapes=$tapes/$ntape programs=$progs/$nprog runs=$runs expectations=$nexp failures=$fails"
[ "$tapes" -gt 0 ] && [ "$tapes" -eq "$ntape" ] || { echo "FAIL: examined $tapes of $ntape tapes"; exit 1; }
[ "$progs" -gt 0 ] && [ "$progs" -eq "$nprog" ] && [ "$runs" -eq $((4 * nprog)) ] ||
    { echo "FAIL: examined $progs of $nprog programs in $runs runs"; exit 1; }
[ -n "$REC" ] || [ "$nexp" -eq $((ntape + nprog)) ] || { echo "FAIL: $nexp expectations for $((ntape + nprog)) cases"; exit 1; }
[ "$fails" -eq 0 ]
