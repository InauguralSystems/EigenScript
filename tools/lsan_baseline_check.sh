#!/bin/sh
# Compare observed tolerated-LSan identities with the reviewed baseline.
# Lines beginning with # and blank lines are documentation, not identities.
set -u
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BASELINE=${EIGS_LSAN_BASELINE:-$ROOT/tests/lsan_tolerated_reports.txt}
OBSERVED=${1:-}
filter() { sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$1" | LC_ALL=C sort -u; }
if [ "${1:-}" = --selftest ]; then
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/eigs-lsan-baseline.XXXXXX") || exit 1
    trap 'rm -rf "$tmp"' EXIT HUP INT TERM
    : >"$tmp/clean"
    if EIGS_LSAN_BASELINE="$BASELINE" "$0" "$tmp/clean" >/dev/null; then
        echo "  PASS: control: reviewed tolerated set is accepted"
    else
        echo "  FAIL: control: reviewed tolerated set was rejected"; exit 1
    fi
    printf '%s\n' '[plant] new-container-store-report — unreviewed' >"$tmp/grown"
    if EIGS_LSAN_BASELINE="$BASELINE" "$0" "$tmp/grown" >"$tmp/out" 2>&1; then
        echo "  FAIL: plant: one new tolerated report stayed green"; exit 1
    elif grep -qF 'new tolerated LeakSanitizer report' "$tmp/out"; then
        echo "  PASS: plant: one new tolerated report makes the gate red"
    else
        cat "$tmp/out"; echo "  FAIL: plant: growth failed for the wrong reason"; exit 1
    fi
    exit 0
fi
[ -n "$OBSERVED" ] && [ -f "$OBSERVED" ] || { echo "FAIL: missing observed tolerated-LSan file"; exit 1; }
tmpb=$(mktemp "${TMPDIR:-/tmp}/eigs-lsan-base.XXXXXX") || exit 1
tmpo=$(mktemp "${TMPDIR:-/tmp}/eigs-lsan-seen.XXXXXX") || { rm -f "$tmpb"; exit 1; }
trap 'rm -f "$tmpb" "$tmpo"' EXIT HUP INT TERM
filter "$BASELINE" >"$tmpb"; filter "$OBSERVED" >"$tmpo"
new=$(comm -13 "$tmpb" "$tmpo")
missing=$(comm -23 "$tmpb" "$tmpo")
[ -z "$new" ] || { echo "FAIL: new tolerated LeakSanitizer report(s), absent from reviewed baseline:"; printf '%s\n' "$new"; exit 1; }
[ -z "$missing" ] || { echo "FAIL: stale tolerated LeakSanitizer baseline entry/entries:"; printf '%s\n' "$missing"; exit 1; }
echo "PASS: tolerated LeakSanitizer reports match reviewed baseline"
