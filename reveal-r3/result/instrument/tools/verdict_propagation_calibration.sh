#!/usr/bin/env bash
# Mechanical calibration that every reached lib/test.eigs verdict turns its section red (#2059).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 2
SELFTEST=0
[ "${1:-}" = "--selftest" ] && SELFTEST=1
[ $# -le "$SELFTEST" ] || { echo "usage: tools/verdict_propagation_calibration.sh [--selftest]" >&2; exit 2; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs_verdict.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
LEDGER=$TMP/ledger; LOG=$TMP/suite.log; : >"$LEDGER"
SUITE_SELECT=""; [ "$SELFTEST" -eq 1 ] && SUITE_SELECT=99aae

(cd "$ROOT" && EIGS_SECTION_TIME=0 EIGS_TEST_FORCE_SUMMARY_FAILURE=1 \
 EIGS_TEST_FORCE_SUMMARY_LEDGER="$LEDGER" \
 EIGS_SUITE_SECTIONS="$SUITE_SELECT" \
 EIGS_VERDICT_PROPAGATION_PLANT="$SELFTEST" bash tests/run_all_tests.sh) >"$LOG" 2>&1 || :

# Attribute FAIL lines to the section opened by the suite's established [label] convention.
awk '/^\[[^]]+\]/{s=$1} /^[[:space:]]*FAIL:/{if(s!="") print s}' "$LOG" | sort -u >"$TMP/red"
awk -F '\t' 'NF >= 2 {print $1}' "$LEDGER" | sort -u >"$TMP/reached"
awk -F '\t' 'NF >= 2 && !seen[$1 SUBSEP $2]++ {print $1 "\t" $2}' "$LEDGER" >"$TMP/records"
awk 'FILENAME==ARGV[1]{red[$1]=1;next}!($1 in red){print}' "$TMP/red" "$TMP/records" >"$TMP/discards"

sections=$(wc -l <"$TMP/reached" | tr -d ' ')
red=$(awk 'FILENAME==ARGV[1]{r[$1]=1;next} $1 in r{s[$1]=1} END{for(x in s)n++;print n+0}' "$TMP/red" "$TMP/reached")
discards=$(awk -F '\t' '!s[$1]++{n++} END{print n+0}' "$TMP/discards")
echo "verdict propagation: sections-in-ledger=$sections sections-red=$red discards=$discards"
echo "verdict discards:"
bad=0; plant_seen=0
while IFS= read -r section; do
    [ -n "$section" ] || continue
    paths=$(awk -F '\t' -v s="$section" '$1==s{print $2}' "$TMP/discards")
    exempt=1; plant=0; display=""
    while IFS= read -r path; do
        rel=${path#"$ROOT"/}; display="${display}${display:+, }$rel"
        awk -F '|' -v p="$rel" '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
            if ($1 == p && $2 ~ /^[[:space:]]*alternate oracle:/) found=1} END{exit !found}' \
            "$ROOT/tests/enrolment_exemptions.txt" || exempt=0
        [ "$rel" = tests/test_verdict_propagation_plant.eigs ] && plant=1
    done <<< "$paths"
    if [ "$SELFTEST" -eq 1 ] && [ "$plant" -eq 1 ]; then
        echo "  RED: $section $display (calibration plant)"; plant_seen=1
    elif [ "$exempt" -eq 1 ]; then
        echo "  EXEMPT: $section $display"
    else
        echo "  RED: $section $display"; bad=1
    fi
done < <(cut -f1 "$TMP/discards" | sort -u)
[ "$discards" -gt 0 ] || echo "  (none)"
if [ "$SELFTEST" -eq 1 ]; then
    [ "$plant_seen" -eq 1 ] || { echo "SELFTEST FAIL: plant was not listed as a discard"; exit 1; }
    [ "$bad" -eq 0 ] || { echo "SELFTEST FAIL: unexpected discard beside plant"; exit 1; }
    echo "PASS: verdict-propagation calibration plant was detected"
    exit 0
fi
exit "$bad"
