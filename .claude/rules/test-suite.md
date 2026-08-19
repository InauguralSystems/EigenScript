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
- **Never re-implement the sanitizer-tolerance decision — source
  `tests/lsan_classify.sh`.** "Is this nonzero exit only a leak report?" was
  open-coded at three sites and drifted at all three: #945/#953
  (`test_doc_examples.py`), #969 (`rc_ok` tolerated a heap-use-after-free
  because a leak line rode along), #968 (`test_sigusr1_dump.sh` read the benign
  `SUMMARY: AddressSanitizer: N byte(s) leaked` as a hard error). There is now
  one classifier, returning leak/hard/none, gated by `tests/test_lsan_classify.sh`
  (corpus of captured compiler-rt output + a mutation train + a differential).
  Two consequences for anyone editing the suite:
  - **A hard diagnostic fails at ANY exit code, including 0.** `ASAN_FLAGS`
    omits `-fno-sanitize-recover`, so UBSan prints `runtime error:` and exits 0;
    ASan under `halt_on_error=0` does the same. Do not add a `rc == 0` fast path
    in front of the classification.
  - **If you `export -f rc_ok` into a child shell, export `lsan_classify` and
    `lsan_classify_name` with it.** `export -f` carries functions only; a child
    missing the classifier took `$? = 127` and inverted both verdicts silently.
    The classifier keeps every pattern *inside* the function for this reason —
    do not hoist them back to file scope.
  - Sites that reject *every* sanitizer marker (`check_task_exit`, `test_lsp.py`,
    `test_dap.py`, sigusr1 subtest 1) are deliberately stricter and do not use
    the classifier's tolerance.
- **Never edit `run_all_tests.sh` (or any child `.sh`) while the suite is
  running.** bash reads a script INCREMENTALLY as it executes — it seeks by
  byte offset — so an edit that shifts line lengths under a running shell can
  make it resume mid-token and execute something nobody wrote. This is
  separate from, and quieter than, the #681 mid-run rebuild guard: that one
  detects a changed BINARY and aborts loudly; nothing detects a changed
  RUNNER. Queue the edit and apply it after the run (2026-08-19, PR #996 —
  two comment additions had to be deferred for exactly this reason).
- **A child `.sh` runs with cwd `src/`, not the repo root** (the runner does
  `cd "$(dirname "$0")/../src"`). Invoking one from the repo root to reproduce
  a failure gives `check ./eigenscript` errors that look like a real failure
  and are not (2026-08-19).
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
