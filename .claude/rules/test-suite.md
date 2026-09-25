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
- **A new file under `tools/` joins FOUR populations, not one.** This branch
  hit three of them in three separate rounds, each as a red CI job:

  | population | what enrols you | how a new tool fails it | verify with |
  |---|---|---|---|
  | `tools/werror_switch_check.sh` ([99i]) | being a TRACKED `*.sh` (`git ls-files '*.sh'`) | a compile line omits the shared `WERROR_FLAGS` reference | `bash tools/werror_switch_check.sh` — its examined count must remain above the floor |
  | `tools/section_plan.sh --gate-audit` (#1160) | the runner dispatching you as `bash "$TESTS_DIR/../tools/NEW.sh"` | any line matching `GATE_ENUM_RE` — **including in a COMMENT** — with no `EIGS-CAP-GATE` marker and no `GATE_WAIVERS` row | `bash tools/section_plan.sh --gate-audit` → `unaccounted=0` |
  | `tools/section_plan.sh`'s child list | the same dispatch spelling | a tool invoked in ANY OTHER spelling is not scanned at all — invisible, not exempt | the audit prints `over the runner + N dispatched children`; N has a floor of 50 |
  | `tools/suite_label_check.sh` ([99w]) | adding a `[NN]` section to the runner | a label another section already echoes | `bash tools/suite_label_check.sh` |

  Plus the doc gates themselves: a backticked `tools/NEW.sh` in a front-door
  document must be git-tracked or produced by a Makefile rule
  with it.

  The one that surprises: **the gate-line audit reads your COMMENTS.** A
  comment quoting the suite's own skip wording counts as an unaccounted
  capability gate, because the audit is deliberately over-broad on spelling
  (mechanical-gates §12) and cannot tell prose from a gate. Waive it with a
  reason rather than rewording — rewording makes the population depend on
  authors avoiding words, which is how a detector stops describing the tree.

- **A new compile command must reference `WERROR_FLAGS`.** `tools/werror_switch_check.sh`
  scans tracked Makefile recipes and shell scripts for compiler commands; a new
  command without that reference fails [99i]. The flags live in
  `tools/werror_flags.txt` and Makefile objects depend on that file.
- **A child `.sh` must not call `timeout` bare.** The macOS CI runners do
  not ship coreutils' `timeout`, so a child that uses it dies rc 127 there
  on its first bounded run — `tests/test_file_exists_fifo.sh`'s first
  version (PR #1077, 2026-09-01) did exactly that and the section went red
  only on the macOS leg. Either bound with pure shell (background the
  child, poll, kill by PID — what that test does now) or copy the runner's
  own probe (`command -v timeout`, else `gtimeout`, else no bound —
  `EIGS_TMO`, run_all_tests.sh:39). `tools/jit_diff.sh` may call `timeout`
  only because its CI job is ubuntu-only.
- **A child `.sh` runs with cwd `src/`, not the repo root** (the runner does
  `cd "$(dirname "$0")/../src"`). Invoking one from the repo root to reproduce
  a failure gives `check ./eigenscript` errors that look like a real failure
  and are not (2026-08-19).
- **`tests/test_temporal.eigs` is line-number-sensitive** — its `at`
  queries hardcode line numbers. Append only before the final if/else, and
  re-verify the `grep -n` markers in the file.
- **Adding a doc example? Every `eigenscript` fence is EXECUTED — opt-OUT**
  (`tests/test_doc_examples.py`, suite [89], over README.md, docs/llms.txt and
  ten `docs/*.md`). Three tags, and nothing else is accepted:
  ```` ```eigenscript ```` followed by an ```` ```output ```` block (stdout
  byte-compared); ```` ```eigenscript fragment i=0 xs=[1,2] ```` (the tag
  declares the snippet's free names, the checker generates `i is 0` lines
  ahead of it, and the run must finish with a clean exit AND clean stderr —
  the runtime prints "undefined variable" to stderr and still exits 0, so the
  exit code alone would accept the exact fault the tag exists to catch);
  ```` ```eigenscript nocheck <reason> ```` (not run, reason required on the
  same line, no backticks in it). An untagged fence with no `output` block
  FAILS. The old un-reasoned `skip` spelling is gone.
  Two things move together when you add a document: `DOC_FILES_ARG` +
  `DOC_POPULATIONS` in the runner, and a `POPULATION` row in the checker —
  `tools/docs_claims_check.sh`'s DOC ENROLMENT class refuses a `docs/*.md`
  with fences and no row, and the checker refuses a run that covered fewer
  pinned rows than exist.
  A fragment's prelude SHIFTS LINE NUMBERS, so an example using `at <line>`
  or `when <n>` must be paired or `nocheck`, never a fragment.
  A fragment's free names are resolved **statically**, through `--lint`'s E003
  pass, not by running it: a name used only inside a branch that never executes
  was never looked up, and such a fragment passed 1/1 with an undeclared
  binding (blind critic, 2026-09-16). Only E003 is read — `--lint` exits
  nonzero on ordinary W-warnings, and gating on its exit code would reject
  correct fragments.
- **Never state a VALUE in a comment inside an executed example.** README.md
  carried `# "converged"  (after 25 steps, loss ~ 1.5e-06)` beside a green,
  byte-compared example whose real answer is 35 steps and
  1.4551915228366852e-09: the example passed, the sentence beside it was wrong
  by three orders of magnitude. Print the value so the paired ```output block
  compares it, or add the exact line to `VALUE_COMMENT_WAIVERS` with a reason.
  The detector is the same expression the class was enumerated with, so a hand
  `grep -nE '#.*(after|gives|prints|≈|~) *[0-9]'` and the gate cannot disagree
  about what the class is.
- **Never hand-type a number into a document.** `tools/docs_claims_check.sh`
  (suite [99za]) derives every numeric claim, repo path, `eigenscript --flag`,
  `make <target>` and backticked `name of` call in README.md, docs/llms.txt,
  CLAUDE.md, docs/ARCHITECTURE.md and docs/BUILTINS.md. Add a derivation rule
  to `NUMBER_RULES`, or waive the EXACT line with a reason. The three numeric
  checks that used to live in `tools/doc_drift_check.sh` moved there; do not
  re-add a number check to `doc_drift_check.sh`.
  **A failing gate must print the tool's OWN WORDS, never a grep for the
  failure you expected.** The macOS job sat at `rc=2` with 28 of 30 plants
  "ABSENT" for two rounds and the reason never reached the log: the section
  captured stderr and then filtered it with `grep -E "^RED|^      "`, which a
  parse error, an unbound variable under `set -u`, or an early `exit` matches
  NEITHER. Print `tail -20` of the captured output, prefixed, plus the exit
  code — the #988 rule ("a child that exited without completing is not
  trustworthy") applies to a gate as much as to a test. Two companions:
  every non-zero exit path in the tool prints one line naming itself, and an
  EXIT trap reports a death that never reached a verdict, with `$BASH_COMMAND`.
  **Every gate prints a one-line ENVIRONMENT BANNER on every run** — shell
  version, make version, `uname`, the binary it selected, whether the release
  binary is present. It is one line in a green log and it is the whole
  diagnosis in a red one; this one would have named the macOS problem in round
  6 instead of round 8.
  **A claim about a BUILD ARTEFACT names its variant; never `src/eigenscript`.**
  That path is a hard link to the LAST-BUILT variant (#740), so a gate that
  measures it measures whatever the job built last: the ASan shard reported
  `claims '940K' but D_BIN_K derives 28721` for the README's binary size
  (2026-09-16, CI). The claim is verified against `build/release/eigenscript`,
  and a lane that did not build release DEFERS it — a named class with a
  declared count (`RELEASE_ONLY_DECLARED`), so a deferral cannot multiply
  unnoticed. A silent skip would have been the easy fix and the wrong one.
  **But "the other lanes verify it" is a claim, and it was FALSE.** Round 7
  wrote that sentence without reading `ci.yml`: every leg builds with
  `./build.sh`, which writes `src/eigenscript` directly, so
  `build/release/eigenscript` never existed in CI and the claim deferred on
  every lane for three rounds. **Before you defer a check to somebody else,
  name the lane and read its steps.** The binary is now identified by INODE
  (`test -ef` compares device and inode): an alias to `build/<v>/eigenscript`
  names its own variant, and a `src/eigenscript` matching none is the
  `./build.sh` product — the install-shaped binary — and is measured.
  **Never suppress the stderr of a scan that feeds a population.** The
  DOC ENROLMENT class ran an ERE through `grep ... 2>/dev/null`; BSD grep
  REJECTED that ERE, so on macOS every document counted 0 fences, the
  population collapsed, and the one sentence that explained it was thrown
  away. §121's declared-count pins fired — they said "examined 0", never WHY,
  and two CI rounds went by not knowing. A failure that looks like "nothing
  found" is the worst shape a scan can take; the diagnostic is what tells them
  apart, so keep it and make it the RED.
  **`grep -o` is not POSIX; do not extract with it.** It is the least portable
  thing in POSIX text processing — GNU and BSD differ on `-o` with `-E`, on
  patterns that can match empty, and on how it composes with `-n`. On macOS the
  docs-claims PATHS scan returned ZERO matches and no error, so the class
  measured nothing while printing a number. Let grep FIND lines and let POSIX
  awk `match()`/`RSTART`/`RLENGTH` EXTRACT. Two rules come with that, because an
  awk dynamic regex is a STRING: no backslash escapes (write `[(]`, `[]]`,
  `[[]` — what `\(` means in a string-to-regex conversion is undefined by
  POSIX), and no `[[:class:]]` and no `\b` (`\b` is a GNU grep extension and a
  backspace to awk; test the following character yourself). Pass the pattern
  through the ENVIRONMENT, never `awk -v`: a -v assignment undergoes escape
  processing and will eat a backslash the pattern needs.
  **"Found nothing" and "failed" are different bugs, and the log must say
  which.** The macOS PATHS scan did not fail; it matched zero times, and all
  the log carried was the consequence ("declared population … was never
  visited") three hundred lines downstream. A scan that returns nothing where
  a count is DECLARED must go red where it happened, quoting the command and
  its exit status.
  **Never pipe a shell BUILTIN into an early-exiting reader — bash 3.2 turns
  the SIGPIPE into output.** `printf … | grep -q`, `| head -1`, `| tail -1` and
  `| awk '… exit'` all stop reading before the writer is done; bash 5 swallows
  the resulting SIGPIPE, bash 3.2 prints `printf: write error: Broken pipe` on
  stderr, and whether it appears at all is a scheduling race. A gate whose
  output is a race cannot be compared run-to-run: this is what broke the
  docs-claims "both build states produce byte-identical output" row on macOS
  for four rounds, and the diff was one stray diagnostic line, not a verdict.
  Use a HERE-STRING (`grep -q PAT <<< "$var"`) — it is a temp file, so there is
  no pipe to break. Same family as tools/pipefail_verdict_check.sh (#1122),
  which polices the pipefail half of it.
  **A selftest row must assert what the PLATFORM does, not what one platform
  does.** The binary-size claim defers off Linux by design; four rows went on
  asserting measurement there and failed for being right. Branch the row, keep
  BOTH branches counted, and print which one ran — a row that silently does not
  apply makes the pinned case count a lie.
  **PARSING IS NOT RUNNING. Run the gate under the old bash, not just
  `bash32 -n`.** The oracle was built in round 10 and used only as a parser for
  three more rounds, each of which shipped a fix for a macOS failure that `-n`
  called clean and each of which was then diagnosed on CI days later. The cause
  was a RUNTIME error: **bash 3.2 scans a PROCESS SUBSTITUTION `<( … )` for its
  closing paren without honouring comments**, so an apostrophe in a comment
  inside one opens a quote that never closes. Measured, both constructs, both
  modes:
  `<( { … # its own file's directory … } )` — `bash32 -n` OK, `bash32` RUN FAILS;
  `$( { … # its own file's directory … } )` — OK in both.
  So `$( … )` bodies are covered by the parse sweep and `<( … )` bodies are
  not. Suite section [99zb] now EXECUTES the shell gates under the old bash.
  `~/.local/bin/bash32 tools/docs_claims_check.sh` reproduces the macOS lane in
  under 20 seconds; use it before believing any portability fix.
  **No `<( … )` or `$( … )` around a multi-line block that can contain a
  comment.** Feed the loop from a temp file (`done < "$tmp"`) and put the
  comment in ordinary shell text. This is the FOURTH apostrophe-class bug in
  one gate — r2 a backtick closed a heredoc, r6 an apostrophe closed a
  single-quoted table, r10 an unbalanced paren broke `$(cat <<EOF)`, r14 an
  apostrophe broke `<( … )` — so the rule is the construct, not the character.
  **`make -p`'s database is version-stable for this Makefile — measured under
  GNU Make 3.81.** macOS runners ship 3.81 (2006) against this box's 4.3, and
  that was the leading suspicion for a macOS-only PATHS failure. Built the
  oracle instead of reasoning about it (`ftp.gnu.org/gnu/make/make-3.81.tar.gz`,
  `./configure && make GLOBINC= GLOBLIB= CFLAGS=-O2` — the bundled `glob/` will
  not link against modern glibc, the system one does, ~90 s): 3.81 and 4.3 give
  the SAME 886 file targets and the SAME 898-entry producer set over this
  Makefile; the only variable-dump difference is `MAKE_HOST`, which nothing
  uses. Suspicion eliminated with evidence, which is the only way this branch
  is allowed to eliminate one.
  **A diagnostic window has a shape, and a tail is the wrong one for a report
  whose evidence is at the top.** Round 8 made the doc-gate sections print the
  child's own words instead of grepping for `^RED` — right — and bounded it at
  20 lines. Three rounds later that bound was the only reason a macOS failure
  stayed unreadable: the class that died printed its work near the START of a
  110-line report. Print everything, and if you must bound it, keep BOTH ends
  and count the elision. Better still, make the last lines diagnostic by
  construction: a per-class summary printed LAST survives any window, and turns
  six consequence-REDs into one sentence naming the class that did not run.
  **A selftest row must build its own premise.** The row asserting "a bare
  src/eigenscript is measured as the build.sh product" ran against the tree's
  real README, whose size describes a RELEASE binary; on the ASan shard
  src/eigenscript is the 28 MB sanitizer build, so the gate measured it,
  disagreed with the document correctly, and the row failed for being right.
  It now derives the number it plants FROM THE BINARY THAT LANE HAS. A row
  that depends on the lane's build state is testing the lane.
  **One grammar, one implementation.** That same class re-implemented
  `tests/test_doc_examples.py`'s fence grammar in shell so it could count
  fences. Two implementations of one grammar exist to disagree. The count is
  now asked of the file that EXECUTES the fences, over a documented interface
  (`--count`, printing `path<TAB>n`).
  **A floor plus a plant calibrated against it drifts apart.**
  `tools/child_exit_check.sh` held a floor of 60 while the population grew to
  113, and its own "population shrunk" planted fault — which removes a fixed
  handful of sites — quietly stopped crossing it. `found == declared` needs no
  calibration and fires in both directions; prefer it to a floor whenever the
  population is enumerable.
  **There is a real bash 3.2 on the dev box: `~/.local/bin/bash32`. Use it.**
  `bash32 -n <file>` answers every "is this portable?" question in one second,
  and `for f in $(git ls-files '*.sh'); do bash32 -n "$f"; done` audits the repo
  in under two seconds. Built from GNU bash 3.2.0 source with
  `./configure --without-bash-malloc --disable-nls && make` (~4 min). Suite
  section [99zb] runs it and ANNOUNCES itself when no old bash is present.
  **Do not infer a portability cause from an error's reported LINE.** Round 9
  read `line 737: syntax error near unexpected token ';;'` and concluded that
  bash 3.2 cannot parse an empty inline `case` arm. It can — verified:
  `case "$1" in a) ;; *) echo x ;; esac` parses under 3.2 cleanly. The error was
  REPORTED at line 737 and CAUSED at line 705, 32 lines earlier. That round's
  fix was harmless and its diagnosis was wrong, and its repo-wide census of
  "latent traps" was a false alarm. An oracle existed one round later and
  settled it in a second.
  **`$( … )` around a quoted heredoc is the trap.** bash 3.2 counts
  parentheses INSIDE a quoted heredoc body, so
  `TABLE=$(cat <<'EOF' … )` breaks the moment a row contains an unbalanced
  `(` — and a row of REVIEWED PROSE quoting someone else's document eventually
  will. **A data table belongs in a data file** (mechanical-gates §53's
  family): `tools/docs_claims_waivers.txt` and
  `tools/docs_claims_populations.txt` are immune to apostrophes, backticks and
  parentheses at once, and a reviewed exemption list is a reviewable artifact.
  That one table produced three quoting traps in three rounds before it moved.
  **An unquoted `(` group inside a `[[ =~ ]]` pattern is a bash 3.2 syntax
  error.** Assign the pattern to a variable and match it unquoted:
  `re='^a(b)c$'; [[ $x =~ $re ]]`.
  **Portable shell is not optional: macOS runners ship bash 3.2 and BSD
  userland.** Three constructs killed `tools/docs_claims_check.sh` there with
  rc 2 before it did anything — `declare -A` (a SYNTAX error in bash 3.2,
  which `tools/failsoft_classify_check.sh` already records), `mktemp -d -p DIR
  TEMPLATE` (BSD mktemp has no `-p`, and its `-t` takes a prefix, not a
  template) and `stat -c %d` (BSD spells it `-f %d`). Use a full path template
  for `mktemp`; use newline-delimited strings plus a `case` substring test
  instead of associative arrays; and prefer DETECTING a condition by attempting
  the operation over asking the platform about it. `tests/run_all_tests.sh`
  and `tools/werror_switch_check.sh` are the local references.
  **A scratch copy for a test goes NEXT TO the repo, never in `/tmp`, and a
  copy that fails is never a skip.** `cp -al` (hard-link copy — the cheap way
  to give a test its own tree) CANNOT CROSS A FILESYSTEM. On the dev box `/tmp`
  and the worktree are the same device so it works; in the CI container the
  workspace and `/tmp` are different mounts, so the copy failed, the helper
  returned early, and three selftest cases silently did not run — 13 red CI
  jobs against a green local ring (PR #1175, 2026-09-16). Put the scratch
  beside the repo (`mktemp -d -p "$(dirname "$ROOT")"`, never INSIDE `$ROOT` —
  copying a tree into its own subtree recurses), fall back to a real `cp -a`
  and PRINT that you did, and give every such helper ONE home. What caught it
  was the pinned count of cases RUN; a count of cases PASSED would have said
  "3 failed" and hidden that 3 more never started.
  **A path that is a BUILD PRODUCT is checked against the Makefile, never
  against the filesystem.** `tools/docs_claims_check.sh` was rc 0 from a clean
  tree and rc 1 *inside the release suite*: section [88] builds `src/eigenlsp`,
  so by [99za] the path existed, the waiver that said "absent from a clean tree
  by design" matched nothing, and the (correct) unmatched-waiver rule fired
  (2026-09-16, exit ring). A waiver is a statement about a REVIEWED LINE; it is
  the wrong instrument for a path whose presence depends on which make targets
  someone ran. Classify first — `git ls-files` for sources, `make -p` for
  products — then ask each class its own question. **A gate whose verdict
  depends on build state cannot be trusted in a suite, because a suite's job is
  to change build state.** Run a new gate from a tree where `make lsp` and
  `make dap` have been run, not only from a clean one.
  A Markdown link resolves against the LINKING FILE's directory and nothing
  else: a repo-root fallback accepted `](docs/STDLIB.md)` written inside
  `docs/BUILTINS.md` (= `docs/docs/STDLIB.md`, which does not exist) and exited
  0 (blind critic, 2026-09-16). If a link needs the fallback, the link is
  broken; fix it, do not waive it.
  Every class also carries a DECLARED per-file count in `DECLARED_POPULATIONS`
  — found == declared, in BOTH directions — because "everything found is
  accounted for" let the population SHRINK: deleting one waived line took
  NUMBERS from 24 to 23 and the gate still exited 0 (blind critic,
  2026-09-16; mechanical-gates §129). Adding or deleting a claim is therefore
  a deliberate edit to that table, and a waiver that matches nothing is red
  with its line quoted.
- **The suite asks the build system whether `src/eigenscript` is current
  before it records the #681 fingerprint (#1089).** A `make` that fails
  partway leaves the PREVIOUS binary linked; a suite launched afterwards
  measured a debug build whose source had already been reverted (25
  failures, `grep` on the tree answering 0, 2026-09-03). `ensure_binary_current`
  finds the variant the alias is hard-linked to, runs `make -q
  build/<variant>/eigenscript` (the FILE target -- the phony goals always
  answer "remake"), and rebuilds through the variant's GOAL (only the goal
  re-points the hard link) with a visible NOTE; a failed rebuild refuses to
  run. It cannot decide for a binary carried in from outside the tree and
  says so instead of gating.
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
- **Never poll for the suite with a process-table match — poll the LOG.**
  `pgrep -f 'run_all_tests'` (and `ps | grep` variants) match the POLLING
  command's own harness wrapper, in both directions: this produced a false
  "suite already running" twice (blocking edits that were safe) and a waiter
  that exited mid-suite once (its own command line matched, then the real
  check misfired), all in one session (2026-08-22/23). The suite's completion
  has an unforgeable artifact — the tally line. Wait with
  `until grep -q 'RESULTS:' "$LOG"; do sleep ...; done`, and if you must ask
  "is a suite live", require a match that excludes your own invocation
  (`ps aux | awk '/run_all_tests\.sh/ && !/awk/'`) and treat a bare pgrep hit
  as unverified. The KILL direction is worse: `pkill -f <pattern>` matches its
  own command line and killed the invoking shell mid-compound (exit 144,
  2026-08-23 — the commit/push/PR after it silently never ran). Kill by PID,
  never by pattern:

      ps -eo pid,cmd | awk '/<pattern>/ && !/awk/ {print $1}' | while read p; do kill "$p"; done

  **This has GRADUATED to enforcement** (2026-09-07). It recurred a fifth time —
  the same agent that had written the rule into its own brief still reached for
  `pkill -f` and lost its shell mid-cleanup — so `bash_guard` now denies
  `pkill`/`killall` at command position and names the PID recipe in the refusal.
  `pkill -P <pid>` is anchored to a known parent and passes. The prose stays
  here for the READ direction (polling with a process-table match), which no hook
  covers; the kill direction is the hook's now, and this note should not grow a
  second copy of it.
