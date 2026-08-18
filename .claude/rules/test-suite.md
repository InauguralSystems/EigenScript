---
paths:
  - "tests/**"
---

# Test-suite rules

- **Suite sections gate on exit codes too** (`rc_ok` in run_all_tests.sh):
  marker-grep alone used to let a crash *after* correct output pass. New
  .eigs sections should use `check_eigs_suite` (rc + marker). The one
  tolerated nonzero exit is a LeakSanitizer report (see the leak tally in
  CLAUDE.md; section **[87]** deliberately opts out of that tolerance and is
  gated strictly leak-clean).
- **`tests/test_temporal.eigs` is line-number-sensitive** — its `at`
  queries hardcode line numbers. Append only before the final if/else, and
  re-verify the `grep -n` markers in the file.
- Adding a doc example? `tests/test_doc_examples.py` runs `docs/SPEC.md` and
  `docs/COMPARISON.md` example/output pairs byte-for-byte (suite [89]/[90]).
  The always-on rule in CLAUDE.md is the merge gate; this is where it lands.
- **`make` does NOT build `src/eigenlsp` or `src/eigsdap`** — only `make lsp`
  and `make dap` do, so the documented local loop (`make && cd tests &&
  ./run_all_tests.sh`) can drive an auxiliary binary from an *earlier tree*
  against tests from the current one. Sections [88] and [126] now gate on
  `make -q <target>` through `tests/aux_binary.sh`, rebuild when the target is
  out of date, and refuse to run if it is still out of date afterwards; the
  `NOTE: … rebuilding` line is surfaced even on a green run. Bought twice —
  #825 (a version-skewed eigsdap made the #411 tape gate refuse every tape and
  18 downstream failures blamed DAP behaviour) and 2026-08-15 (an eigenlsp one
  day old failed exactly the five new #935 assertions while clearing the
  #942/#944/#947 queue, costing a full extra suite run to exonerate the code).
  Do **not** substitute a `--version` comparison: both binaries read `0.39.0`
  while their sources differed by a day. Do not substitute an mtime glob over
  `src/*.[ch]` either — that misses `src/freestanding/*.h`, the Makefile, and
  every generated header. Ask the build system.
  The expensive direction is not the phantom failure but the phantom **pass**:
  a stale binary predating a regression reports its whole section green.
- **A `.eigs` test file must end with `test_summary of null`, never its own
  `print of "All tests passed"`.** The runner's marker-grep is satisfied by
  either, but only `test_summary` exits nonzero on a failed assertion —
  `test_sandbox_budget.eigs` printed the marker unconditionally and reported
  green over a genuinely red assert for weeks (caught by a blind review,
  2026-08-17, fixed with a planted-flip proof).
