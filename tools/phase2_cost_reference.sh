#!/usr/bin/env bash
# Print the single pre-number-model commit used by both Phase 2 cost gates.
set -u
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
name_file=${PHASE2_COST_REFERENCE_FILE:-$root/tests/phase2/cost_reference.txt}
[ -r "$name_file" ] || { echo "phase2-cost-reference: FAIL: missing or unreadable name file: $name_file" >&2; exit 2; }
sha=$(cat "$name_file")
[ -n "$sha" ] || { echo "phase2-cost-reference: FAIL: empty name file: $name_file" >&2; exit 2; }
[ "${#sha}" -eq 40 ] || {
  echo "phase2-cost-reference: FAIL: name must be exactly 40 lowercase hex digits" >&2; exit 2; }
case "$sha" in *[!0-9a-f]*)
  echo "phase2-cost-reference: FAIL: name must be exactly 40 lowercase hex digits" >&2; exit 2;; esac
[ "${1:-}" = --fetch-name ] && { printf '%s\n' "$sha"; exit 0; }
[ "$#" -eq 0 ] || { echo "phase2-cost-reference: FAIL: usage: $0 [--fetch-name]" >&2; exit 2; }
git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null || {
  echo "phase2-cost-reference: FAIL: named object is not a commit of this clone: $sha" >&2; exit 2; }
if git -C "$root" cat-file -e "$sha:tests/phase2/cost_expect.txt" 2>/dev/null; then
  echo "phase2-cost-reference: FAIL: named commit already holds tests/phase2/cost_expect.txt: $sha" >&2; exit 2
fi
printf '%s\n' "$sha"
