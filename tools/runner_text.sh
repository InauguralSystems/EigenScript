#!/usr/bin/env bash
# Print the runner as the static-analysis gates must see it: the main file with
# its deterministic section-fragment directory expanded at the source seam.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
runner="${1:-$ROOT/tests/run_all_tests.sh}"
sections="${2:-$(dirname "$runner")/sections}"
awk -v sections="$sections" '
  $0 == "# EIGS_SECTION_FRAGMENTS" {
    cmd = "find \"" sections "\" -maxdepth 1 -type f -name \047*.sh\047 -print 2>/dev/null | LC_ALL=C sort"
    while ((cmd | getline f) > 0) {
      while ((getline line < f) > 0) print line
      close(f)
    }
    close(cmd)
    skipping = 1
    next
  }
  skipping && $0 == "# EIGS_SECTION_FRAGMENTS_END" { skipping = 0; next }
  skipping { next }
  { print }
' "$runner"
