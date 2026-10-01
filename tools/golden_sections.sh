#!/bin/bash
# Section-level stdout/stderr oracles for #1298. The section planner remains
# the sole parser of runner boundaries.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
RUNNER="$ROOT/tests/run_all_tests.sh"
GOLDEN="$ROOT/tests/golden/sections"
IDS='99u 1/15 133 47/47 42a'
die() { echo "golden_sections: ERROR: $*" >&2; exit 2; }
key_for() { printf '%s' "$1" | tr '/' '-'; }
selector_for() { case "$1" in 1/15) echo 1;; 47/47) echo 47;; *) echo "$1";; esac; }
known() { case " $IDS " in *" $1 "*) return 0;; *) return 1;; esac; }
inventory() {
    awk '/^echo "\[[^]]+\]/ {if(id!="")print n"\t"id; id=$0;sub(/^echo "\[/,"",id);sub(/\].*/,"",id);n=0} id!=""&&($0~/grep/||$0~/=~/||$0~/diff/||$0~/cmp/){n++} END{if(id!="")print n"\t"id}' "$RUNNER" | sort -rn | head -5
}
run_one() {
    id=$1; mode=$2; key=$(key_for "$id")
    work=$(mktemp -d "${TMPDIR:-/tmp}/eigs_golden.XXXXXX") || die 'mktemp failed'
    trap 'rm -rf "$work"' EXIT
    plan="$work/plan.sh"; selector=$(selector_for "$id")
    bash "$ROOT/tools/section_plan.sh" --emit-sections "$selector" "$plan" --quiet >/dev/null || die "planner rejected section '$id'"
    EIGS_GOLDEN_CHILD=1 EIGS_SECTION_TIME=0 bash "$plan" >"$work/log.stdout" 2>"$work/log.stderr"; rc=$?
    awk -v h="[$id]" 'index($0,h)==1{on=1} on&&/^@@EIGS-CHUNK [0-9]+@@$/{exit} on&&$0!~/^SECTION_TIME:/{print}' "$work/log.stdout" >"$work/actual.stdout"
    cp "$work/log.stderr" "$work/actual.stderr"
    if [ "$mode" = bless ]; then
        mkdir -p "$GOLDEN"
        mv "$work/actual.stdout" "$GOLDEN/$key.stdout.new"; mv "$work/actual.stderr" "$GOLDEN/$key.stderr.new"
        mv "$GOLDEN/$key.stdout.new" "$GOLDEN/$key.stdout"; mv "$GOLDEN/$key.stderr.new" "$GOLDEN/$key.stderr"
        echo "golden_sections: blessed [$id] ($key.stdout, $key.stderr; section rc=$rc)"
    else
        for stream in stdout stderr; do
            exp="$GOLDEN/$key.$stream"; act="$work/actual.$stream"
            [ -f "$exp" ] || die "missing expected output: $exp"
            if ! diff -u "$exp" "$act"; then
                echo "golden_sections: mismatch [$id] $stream" >&2; echo "  expected: $exp" >&2; echo "  actual:   $act" >&2; exit 1
            fi
        done
        echo "golden_sections: PASS [$id] stdout/stderr (section rc=$rc)"
    fi
}
case "${1:-}" in
 --inventory) [ "$#" -eq 1 ] || die '--inventory takes no arguments'; inventory ;;
 --check|--bless) [ "$#" -eq 2 ] || die "$1 requires exactly one canonical section ID"; known "$2" || die "unknown or ambiguous section '$2' (choose one of: $IDS)"; run_one "$2" "${1#--}" ;;
 *) die 'usage: golden_sections.sh --inventory | --check <section> | --bless <section>' ;;
esac
