#!/usr/bin/env bash
set -u
if [ "${1:-}" != --selftest ]; then echo "usage: $0 --selftest" >&2; exit 2; fi
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
reader="$root/tools/phase2_cost_reference.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cost-reference-test.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
pass=0
check_fail() { # label expected-pattern [file contents; absent when omitted]
  label=$1 pattern=$2 contents=${3+x}
  file="$tmp/$label"; [ -z "$contents" ] || printf '%s' "$3" > "$file"
  PHASE2_COST_REFERENCE_FILE="$file" "$reader" >"$tmp/out" 2>&1; rc=$?
  if [ "$rc" -eq 2 ] && grep -q "$pattern" "$tmp/out"; then echo "PASS: $label"; pass=$((pass+1));
  else echo "FAIL: $label rc=$rc expected=$pattern"; cat "$tmp/out"; exit 1; fi
}
valid=$(cat "$root/tests/phase2/cost_reference.txt")
printf '%s\n' "$valid" > "$tmp/valid"
PHASE2_COST_REFERENCE_FILE="$tmp/valid" "$reader" > "$tmp/out" || { cat "$tmp/out"; exit 1; }
[ "$(cat "$tmp/out")" = "$valid" ] || exit 1
echo 'PASS: valid named pre-number-model commit'; pass=$((pass+1))
check_fail missing 'missing or unreadable'
check_fail empty 'empty name file' ''
check_fail short 'exactly 40 lowercase hex' '123456789012345678901234567890123456789'
upper=$(printf '%s' "$valid" | tr a-f A-F); [ "$upper" != "$valid" ] || { echo "FAIL: upper: $valid has no a-f"; exit 1; }
check_fail upper 'exactly 40 lowercase hex' "$upper"
check_fail relative 'exactly 40 lowercase hex' '1c2890b3~0000000000000000000000000000001'
check_fail noncommit 'not a commit of this clone' '0000000000000000000000000000000000000000'
head=$(git -C "$root" rev-parse HEAD)
check_fail model 'already holds tests/phase2/cost_expect.txt' "$head"
echo "cost-reference-selftest: $pass passed, 0 failed"
