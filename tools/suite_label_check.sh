#!/usr/bin/env bash
# #1025: suite section labels must be unique. Two DISTINCT sections printing the
# same "[NNx]" label read as one block when a CI log is grepped by name -- five
# pairs had accumulated (a long-parked branch rebased onto a main that had
# meanwhile taken the next letter is the recurring shape). One section MAY echo
# its label more than once, for its conditional twin ("... SKIPPED (binary
# built without ...)", a minimal-build stub check), so the rule is: every echo
# of a label after the first must be such a twin, recognised by the twin's
# own phrasing -- "SKIPPED (binary built without ...)", "skipped — no gfx
# build", "stub check", "minimal build" -- NOT by the word "skipped" anywhere
# (a real section titled "Skipped-Test Counter Audit" must still collide).
# Labels are any bracketed text ([Call Semantics] counts as much as [99v]). Vacuity guard: the scan must
# find at least MIN_LABELS labelled echo lines, or the runner has changed shape
# under it and the check would pass by seeing nothing.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="${SUITE_LABEL_RUNNER:-$ROOT/tests/run_all_tests.sh}"
RUNNER_TEXT=$(mktemp "${TMPDIR:-/tmp}/eigs_labels.XXXXXX") || exit 2
trap 'rm -f "$RUNNER_TEXT"' EXIT
bash "$ROOT/tools/runner_text.sh" "$RUNNER" > "$RUNNER_TEXT" || exit 2
RUNNER="$RUNNER_TEXT"
MIN_LABELS=200
n=$(grep -cE '^[[:space:]]*echo "\[[^]"]+\]' "$RUNNER")
if [ "$n" -lt "$MIN_LABELS" ]; then
  echo "FAIL: suite_label_check found only $n labelled echo lines (< $MIN_LABELS) -- the scan is vacuous"; exit 1
fi
# #1372: a label carries no hand-typed check count. "[88] LSP Behavioral (80
# checks)" ran 148; a count typed into a label drifts on every added test, and
# the section's own PASS line already prints the real one.
# A count is a number standing alone (after a space, "(" or ","), then up to
# three words, then check(s)/test(s)/case(s), in any case: "(148 LSP checks)"
# is one; "UTF-8 tests", "IPv4 tests" and "SHA-256 checks" are names.
counted=$(grep -niE '^[[:space:]]*echo "\[[^]"]+\][^"]*[(, ][0-9]+( [a-z][a-z0-9-]*){0,3} (checks?|tests?|cases?)([^a-z]|$)' "$RUNNER")
if [ -n "$counted" ]; then
  printf 'FAIL: section label carries a hand-typed count (#1372):\n%s\n' "$counted"; exit 1
fi
grep -nE '^[[:space:]]*echo "\[[^]"]+\]' "$RUNNER" \
  | sed -E 's/^([0-9]+):[[:space:]]*echo "\[([^]"]+)\](.*)$/\2\t\1\t\3/' \
  | sort -t$'\t' -k1,1 -k2,2n \
  | awk -F'\t' '
      BEGIN { prev = "<none>" }   # NOT "" -- awk compares an uninitialised var NUMERICALLY, and "" == "0"
      $1 == prev {
        if ($3 !~ /SKIPPED \(|skipped — |stub check|minimal build/) {
          printf "FAIL: label [%s] echoed at lines %d and %d -- two sections share one name\n", $1, first, $2; bad = 1
        }
        next
      }
      { prev = $1; first = $2 }
      END { exit bad ? 1 : 0 }'
rc=$?
[ $rc -eq 0 ] && echo "PASS: $n labelled echo lines, no two sections share a label"
exit $rc
