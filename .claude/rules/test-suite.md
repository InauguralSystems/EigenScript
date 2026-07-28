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
