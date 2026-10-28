#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 2
if [ "${1:-}" = --selftest ]; then
    [ $# -eq 1 ] || { echo "usage: $0 --selftest" >&2; exit 2; }
else
    echo "usage: $0 --selftest" >&2; exit 2
fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs-plan.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
bad=0
for plant in short missing-plan; do
    log="$TMP/$plant"
    (cd "$ROOT" && EIGS_SECTION_TIME=0 EIGS_SUITE_SECTIONS=99aaf EIGS_PLAN_PLANT="$plant" bash tests/run_all_tests.sh) >"$log" 2>&1; rc=$?
    if [ "$rc" -ne 0 ] && grep -q '^  FAIL: child plan contract:' "$log"; then
        echo "  PASS: $plant plant turned its real suite section red"
    else
        echo "  FAIL: $plant plant was not red (rc=$rc)"; tail -20 "$log"; bad=1
    fi
done
echo "PLAN: 2"
[ "$bad" -eq 0 ]
