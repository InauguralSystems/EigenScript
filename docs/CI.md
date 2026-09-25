# CI: what runs on your PR, what runs on main, what runs nightly

Continuous integration here has three lanes. This page says which gate lives
where, why, and what a contributor should expect to wait for.

## The measurement that forced the split

PR #1158 (head `8cc1f2d`, 26 checks, all green):

| Check | Minutes |
|---|---|
| macos / macos-15-intel | 35 |
| asan + ubsan / HTTP and model full suite | 26 |
| asan + ubsan / core and LSP | 22 |
| extensions / http+model and ancillary checks | 20 |
| macos / macos-latest | 15 |
| linux / gcc | 13 |
| extensions / zlib, net, gfx full suite | 13 each |
| db extension (postgres service) | 12 |
| linux / clang | 10 |
| replay differential, freestanding, CodeQL C | 2 each |
| valgrind, jit differential, install, bench, tsan, scope | ≤ 1 each |

35 minutes of wall clock, about 200 machine-minutes. Two findings:

1. **The same full suite ran in TEN jobs** — gcc, clang, zlib, net,
   gfx, http, db, asan-core, asan-http, two macOS — differing only in the
   extension surface of the binary they built. A zlib build has exactly one
   section the gcc build does not; it paid for all of them.
2. **Section [99i] ran a large compile-line audit inside every suite job.**
   The old gate dry-ran Makefile targets and scanned scripts, adding minutes
   per run for a property that now follows from one shared flags file.

## PR lane (`pull_request`)

- `scope` skips runtime steps for a docs-only PR. The doc gates still run.
- Linux gcc and clang, HTTP+model, gfx, zlib, net, and the PostgreSQL full
  build each run the complete suite against their own binary.
- The HTTP+model ASan binary runs the complete suite across weight-balanced
  shards. The required aggregator verifies coverage and the leak tally.
- `macos-latest` runs on the PR; `macos-15-intel` runs nightly.
- Differential, compiler, doc, and gate self-tests continue on their existing
  jobs. The separate playground workflow builds real wasm32 on every PR.

## The playground: the real wasm32 build, on the PR

The browser playground is `web/build.sh` compiled by emcc (wasm32). Until #1255
the only place that ran was `.github/workflows/pages.yml` on **push to
`main`** — after the merge. It was red on `main` for five commits in a row
(517cf08 back to 0ac8a9b) before anyone looked, because nothing on a pull
request compiled for the real target.

The local gate did not catch it either, and could not. The suite's ILP32
gate compiled every translation unit the recipe hands the compiler with host
`clang -m32` — the **i386** ABI. i386 aligns `double` to 4 inside a struct;
wasm32 aligns it to 8. The Value union was 36 bytes under `-m32` and 40 under
emcc, so a layout `_Static_assert` held under the gate and failed the real
build. That approximation was deleted in #1274: the real build below runs on
every change it could have guarded, and an approximation of a required target
is a second, weaker answer to the same question.

What is true now:

- **pages.yml builds the playground on every pull request and every push to
  `main`, and nothing decides whether to.** There is no path filter and no
  "was the playground touched?" step. Round 1 of #1255 path-filtered the
  trigger (so the check could not be required); round 2 replaced that with a
  `scope` job reading `git diff --name-only`, which under git's default rename
  detection lists only a renamed file's NEW path — moving `src/trace.h` to
  `attic/trace.h` read as "untouched", skipped the build, and passed a recipe
  that no longer compiles. Two rounds, one class, and the build costs ~72 s
  against a ~45-minute CI run, so the decision is gone rather than patched:
  - `playground / build (real emcc, web/build.sh) + docs site` is the worker.
    It runs the **same** `bash web/build.sh` — one recipe, no second copy of
    the emcc flags — unconditionally, and it leaves a receipt (`built=true`)
    only after the build exited 0 and produced the wasm module and its loader.
  - **`playground (real emcc wasm32 build)`** is the aggregator (`if:
    always()`, the shape of ci.yml's aggregators, see **The PR-lane job set,
    and which are aggregators** below). It succeeds only when the worker
    succeeded AND left the receipt. With no scope left to combine it still
    earns its place: a skipped job reads as passing to a required-check rule
    and a cancelled one leaves nothing, and the aggregator makes both a
    failure; it also keeps the requirable NAME independent of the worker's.
    It reports on **every** PR, so it can be required.

  Configure Pages, the artifact upload and the `deploy` job are gated to
  non-PR events, so deploy still happens only from `main`. A PR gets its own
  concurrency group, so a PR push can never cancel a `main` deploy. Measured
  on `main`, the build job is about 72 s with the emsdk cache warm, and every
  PR pays it.

**The required check is `playground (real emcc wasm32 build)`** — the
aggregator, never the worker alone (a skipped worker reads as passing). It is
listed in `.github/required-checks.txt`, so a red wasm build blocks the merge.

## The doc gates — where they run, and why they are cheap

These live checks run on the Linux legs of the PR lane. Changes to their
inputs also select their separate checker calibrations.

| Section | Tool | What it refuses |
|---|---|---|
| **[89]** | `tests/test_doc_examples.py` | an eigenscript fence that is not executed. Opt-OUT: paired with an `output` block (byte-compared), tagged `eigenscript fragment k=v ...` (free names declared in the tag, resolved STATICALLY through `--lint` E003 so a name hiding in a dead branch still counts, then run and required to finish clean), or tagged `eigenscript nocheck <reason>`. Anything else is red. It also refuses a **value stated in a comment** inside an executed example — that is a claim wearing a checked example's clothes. Per-file populations are pinned and cross-checked against an independent line scan. |
| **[99za]** | `tools/docs_claims_check.sh` | dangling repo paths and Markdown links, unknown `eigenscript --flag` references, missing `make` targets, unresolved backticked calls written with `of`, missing stdlib guide headings, and executable fences without enrolment. Paths come from `git ls-files` or Makefile products; flags from the real `--help`; names from `--api` and compiler vocabulary. Each reference class has a nonempty population and per-document floors in `tools/docs_claims_populations.txt`; fence enrolment has declared rows. Derived counts belong in commands, not prose. |
| **[99zb]** | `tools/portability_parse_check.sh` | a tracked `*.sh` that the OLDEST bash on the machine cannot parse — **or a shell gate it cannot RUN**. macOS ships **bash 3.2 (2007)**, and three CI rounds were spent guessing at what it rejects — twice wrongly. The dev box now carries a real one at **`~/.local/bin/bash32`**, built from GNU bash 3.2.0 source with `./configure --without-bash-malloc --disable-nls && make` (~4 min); `bash32 -n <file>` settles any portability question in a second, and the whole repo in under two. Parsing was never enough: bash 3.2 scans `<( … )` for its closing paren **without honouring comments**, so an apostrophe in a comment inside one opens a quote that never closes — at RUNTIME, which `bash -n` calls clean. That kept the macOS lane red for four rounds. The audit also executes the live gates listed in its `RUN_TARGETS` table under the old bash and requires rc 0, with the run count pinned. Checker calibration belongs to the change-selected driver. When no old bash is present the check **announces the skip and prints both counts** AND names every candidate it looked at, so it can never read as a completed audit. The file count, the gate count and the oracle are printed by the check itself (`portability: OK: files=… checked=… parse-failures=0; gates-run=…/… run-failures=0 (oracle …)`) rather than typed here, because a number typed into a page about a count that moves is a number that rots. **The system shell is a candidate when it IS old** (round-5 blind critic, Fable): until then the candidate list was `$PORTABILITY_BASH` and the two `bash32` oracle paths and nothing else, so on the one platform this audit exists for — the macOS runner, whose default `/bin/bash` IS GNU bash 3.2.57 — it found no old bash and skipped with "NO OLD BASH ON THIS MACHINE". That reason was false; the list simply never tried `/bin/bash`. `/bin/bash` and `/usr/bin/bash` are now candidates **when their own `BASH_VERSINFO[0]` is ≤ 3**, so the macOS lane runs the real audit and a Linux runner's bash 5 is never mistaken for an oracle. **Round 6: EVERY candidate is asked its own version, including the declared ones** — `$PORTABILITY_BASH` and the two `bash32` paths were trusted BY NAME, and a file called `bash32` is not bash 3.2 (a symlink to the system shell, or a rebuild that picked up a modern source), so the gate could print a truthful `oracle=… version 5.x` receipt for an audit that models nothing; a name is a hint, `BASH_VERSINFO[0]` is the fact. The skip line names every candidate it looked at AND every one it rejected by version, and those lines now reach the CI log. **The CALLER pins the identity too, and it keys on the FACT rather than the banner**: the gate prints `portability-parse: oracle-major=N` from the SELECTED candidate's own `BASH_VERSINFO[0]`, and `[99zb]` parses THAT line while holding its own `≤ 3` literal. Round 6 read the major version out of the GNU version banner instead, so a real bash 3.2 behind a wrapper whose banner says `Custom Bash 3.2.0` yielded no number at all and was failed BY NAME (round-6 blind critic, Fable) — a banner is prose, a version is a fact. A gutted selection is still red by name (`the portability gate measured under bash 5 — that is not the old shell it exists to model`) rather than passing on rc 0 and a verdict prefix. The portability checker's self-test drives the suite's real receipt-classifier function over synthetic positive and negative receipts when that checker or the suite changes, and nightly. |

The reference checker reads source paths from `git ls-files`, build products
from `make -p`, CLI flags from `eigenscript --help`, and call names from
`eigenscript --api`. Its calibration plants one fault per class and checks
an honest control. The live check stays in the suite; calibration runs when
its inputs change or in nightly checks.

**The doc set [99za] walks** is named in `tools/docs_claims_check.sh`:
README.md, docs/llms.txt, CLAUDE.md, docs/ARCHITECTURE.md,
docs/BUILTINS.md, docs/CONCURRENCY.md, ROADMAP.md and this page.
This page is exempt from the FLAGS class because it documents flags for
other tools; it remains enrolled for the other reference classes.
The gate uses `tests/test_doc_examples.py --count` to find executable fences
and checks that each document with one has a POPULATION row.
Direct example-runner calls require file arguments; the suite supplies its
declared POPULATION list.

The doc parser gate retains its calibration, and the reference checker has
a planted-fault calibration in the self-test table. Their live checks stay in
the suite; calibrations run when inputs change or in nightly checks.

To add a document to [89]: add it to `DOC_FILES_ARG` in the runner AND a row to
`POPULATION` in `tests/test_doc_examples.py`, and bump `DOC_POPULATIONS`. The
checker refuses a document that carries fences and has no pinned row, and the
suite refuses a run that covered fewer rows than are pinned — a file quietly
dropped from either list is a failure at both ends.

## Issue labels

**Every open issue carries an `area:` label and a kind.** The scheme is
`area:<subsystem>` (runtime-vm, jit, concurrency, observer, memory,
trace-tape, packages, http, gfx, embed, docs, ci, gates, lint-tooling,
consumer, aot, stdlib) plus a KIND (`kind:silent-wrong`, `kind:gate-defect`,
`kind:docs-drift`, `kind:flake`, `kind:tracking`, `kind:decision`, or the stock
`bug`/`enhancement`); `found-by:*` and `blocks-release` are optional.

`.github/workflows/issue-triage.yml` keeps it that way, reading GitHub's own
issue list with `gh` and `jq`:
- **`triage`**, on an issue opened or reopened, adds `needs-triage` when it
  has no `area:` label, and comments with the scheme.
- **`audit`** runs daily and on `workflow_dispatch`. It prints
  `examined=N missing=M` and fails when any open issue lacks either label, or
  when it listed no issues at all.

This is housekeeping, so it never runs in the test suite or on a pull request.
While it was a suite section, one unrelated unlabelled issue turned every PR
red and ejected queued merges (#1279, #1168).

**ROADMAP.md does not mirror the milestones.** The milestone set, with each
milestone's bar, lives on GitHub; ROADMAP.md links it and holds only
uncommitted ideas, vetoes and shipped history. Nothing is copied, so there is
nothing to check for drift (#1275).

`tools/workflow_yaml_check.sh` loads every file under `.github/workflows/`:
(a) no `name:` value is an unquoted plain scalar containing `: ` — the exact
defect round 1 shipped, which made the daily issue-triage lane unloadable YAML
that GitHub would have rejected outright — and (b) every file round-trips
through a real YAML loader. Arm (a) never skips; arm (b) skips by name without
PyYAML. A load proves the bytes parse and carry a `jobs:` mapping — it does NOT
prove GitHub's own workflow schema accepts the file.

Arm (a) tokenises the scalar the way YAML does before looking for `: `: a
trailing ` #` comment is stripped, a quoted scalar is skipped whole, and lines
inside a `|`/`>` block scalar are skipped until the block dedents. It used to
reject all three of those as faults, and a gate that fails correct input is a
gate somebody turns off. The gate's selftest is SKIP-AWARE for the same reason:
two of its plants can only go red through arm (b), and on a runner without
PyYAML they were scored "did NOT go red" — which took three suite legs red at
once. A plant whose arm skipped by name is now scored `SKIP` and reported in
the pinned `SELFTEST:` line. The runners install PyYAML so arm (b) actually
runs (`python3-yaml` in `.devcontainer/Dockerfile` for every Linux leg, a setup
step on the macOS lane); when it is absent anyway, the CALLER probes for PyYAML
itself and allows exactly the pinned named-skip count, for that gate alone.

The suite runs the live `tools/workflow_yaml_check.sh` as `[99zd]`,
the only part of that section that reads nothing but the tree.

## Main lane (the merge queue, then push to `main`) — the full matrix

Everything above runs in full: macOS (`macos-latest`), every variant job on the
complete suite, `linux / clang` on the complete suite. [99i] is now cheap enough
to run in each suite, as well as in its required CI job.

This is the real exit gate, and it runs **in the merge queue** (`merge_group`)
on the commit that will land, before it lands — see **Platform tiers** below.
#1138 and #1158 both carried lanes only CI could run. Contributors never wait
on it and never rebase to satisfy it; the queue does both.

## Nightly (`.github/workflows/nightly.yml`)

- `macos-15-intel`, the full suite — the 35-minute job that used to set the PR
  wall clock. Intel-mac-only shapes are real; they can lag a day.
- **valgrind over the whole runnable corpus**, not the fixed smoke spread
  (`tests/valgrind_smoke.sh --full`). This is the ONLY lane that runs the full
  corpus: both the PR lane and `main` run the smoke spread. The spread's size
  is not written down anywhere — `valgrind_smoke.sh` prints `programs=<n>` from
  `${#PROGS[@]}`, because the last three documents that hard-coded it said 28
  when the list held 27.
- All gate self-tests, including those unchanged since the previous night.
- A failure opens — or appends to — a single tracking issue, so a nightly that
  nobody is watching still reaches someone. A green run after a red one
  comments on the same thread, which is what makes the thread closable.

## Section planner and skip accounting

`tools/section_plan.sh` splits the runner into complete top-level chunks and
verifies that the preamble, chunks, and epilogue reconstruct it byte for byte.
It assigns every chunk to one sanitizer shard by measured weights from
`tests/section_weights.txt`. The coverage check requires an exact, nonzero
chunk population, a complete union, disjoint assignments, and a nonempty set
of chunks for every shard. The shard count is checked against the CI matrix
and every `/N` literal.

The same tool audits the runner's `SKIP` emitters and `section_skip` calls.
Their populations are exact and nonzero; each emitter has a reviewed reason
or is routed through the helper that counts it in `RESULTS`.

```bash
bash tools/section_plan.sh --chunks
bash tools/section_plan.sh --shards 3 --check
bash tools/section_plan.sh --shard-owner 3 --section '[88]'
bash tools/section_plan.sh --skip-audit
bash tools/section_plan.sh --selftest
EIGS_SUITE_SHARD=2/3 bash tests/run_all_tests.sh
```

A shard forces section timing on. The outer runner counts visible
`SECTION_TIME` records and visible `[...]` headers, then emits its numeric
`sections=` plan line only when the counts agree and are nonzero. A
zero-assertion suite also fails.

### Consumer acceptance wave

`CA_ECO=... bash tools/consumer_acceptance.sh plan` scans pinned sibling
checkouts. `plan --cmd <consumer>` prints that consumer's complete acceptance
command, taken from its CI workflow `runCmd` or the explicitly declared commands.
The scanned inventory must cover the recorded inventory floor, and every
consumer needs a command. The commands returned by `plan` are compared
byte for byte with the pre-change oracle when this gate changes.

`run <tree-or-binary> [--full binary] [--gfx binary]` runs each command in its
checkout. A tree argument selects `src/eigenscript`; a binary symlink is
resolved before walking to its candidate tree. When a source tree is found,
its `src/eigenscript` or `build/release/eigenscript` must match the resolved
binary by inode or SHA256. A standalone binary gets a minimal overlay;
`CA_TREE=<dir>` explicitly overrides the tree check and is recorded.
The base and supplied variant binaries are hashed before the rows start. A
shim directory is first on the inherited
`PATH`; its `eigenscript`, `eigenscript-full` and `eigenscript-gfx` entries
execute the original resolved binary paths and log calls, preserving
executable-relative standard-library loading. Each supplied binary is hashed
again after every row; a changed hash makes that row `FAIL` with
`candidate-mutated:<name>`. An unsupported runtime variant is
`UNRUNNABLE` by name. `EIGS_DIR` and `EIGENSCRIPT_DIR` point to a private
copy of the candidate tree's `src/`, `lib/` and top-level regular files;
`build/` is not linked in. Its extensionless runtime executable slots use
the same counting shims, while `.c` and `.h` source files remain intact.
Consumer writes and builds there do not alter the candidate tree. Named
external tools and the gfx capability are probed before affected rows;
missing prerequisites yield `UNRUNNABLE|prereq=<name>`. The harness no longer
builds a PATH farm or changes `HOME`.

Every row records its verdict, exit code, elapsed seconds and candidate call
counts. A command that exits zero without a candidate call fails. A timeout
is `HANG` with rc 124 or 137. The floor is read from completed records,
including the target record, before that target is marked `INCOMPLETE`.
Traps are then installed before the first candidate hash, tree inspection,
git metadata, scratch and shim setup;
a signal leaves `VERDICT: INCOMPLETE` as the final line. A complete record
is published by atomic replacement and passes only
when `examined == inventory > 0`, all required consumers are present, and
every row passes. Without `CA_RECORD`, the record survives under
`reports/consumer_acceptance/<UTC date>-candidate.record`; the candidate
tree's short git SHA is recorded in `candidate_git_sha=` when available.
The existing
2026-09-20 wave record remains readable with the same `row|` columns and
header/footer format. `--self-test` plants faults once when the harness
changes; it is not a permanent check of every internal branch.

## The ASan suite runs in shards

Measured on the first real PR run of this change (run 34962403732, head
25ade7e): **21.1 min wall, 27 checks green** — down from 35, but over the bar.
The whole critical path was one job:

| Job | min |
|---|---|
| `asan + ubsan / core and LSP` | **19.0** (build 4.7 + suite 13.9) |
| `linux / gcc` | 9.5 |
| `macos / macos-latest` | 9.4 |
| `asan + ubsan / HTTP and model` | 7.8 |
| everything else | ≤ 6.2 |

The leak-tally gate must cover the **full** suite, so the current HTTP+model
ASan build runs it in parallel shards. In the original core-only measurement,
with ~2 min of queue and a 4.7-min ASan build in front,
`queue + build + 13.9/N` gives 20.6 / 13.7 / **11.3** / 10.2 for N = 1/2/3/4.
N=2 clears 15 by 1.3 min, which is inside runner noise; N=3 clears it by 3.7;
past N=3 the *build* dominates and a fourth shard buys 1.1 min for another 4.7
build-minutes. **N = 3.**

**Historical core-only shard measurement: 13.4 min wall on run 35020270020 (head c4c23ae), then 15.0 min on
run 35036548663 (head 418d62d) — 35 → 21.1 → 13.4 → 15.0.** The regression was
not the split: the runner-measured weights worked, and the three suite steps
came in at 290 / 285 / 278 s against a predicted 319 / 272 / 272. It was the
job-level LSP step, hard-wired to shard 1, jumping from 1.5 s to 267 s (see
below). With both extras' owners derived, the predicted lane is **~11.5–12.5
min**, with the critical path moving off shard 1.

The historical lower bound was one section, not the arithmetic: `[137]` (the ext_gfx
ASan/LSan corpus) costs **319 s of the 862 s** the whole sharded suite takes on
the runner — 37% — and a section is indivisible, so no N can put the slowest
shard below 319 s. N=4 would not help. Splitting `[137]` itself is the next
lever if this lane ever needs to be faster.

**A shard is a subset of the chunk list**, so "the shards cover the suite" is a
set identity rather than a belief:

```bash
tools/section_plan.sh --shards 3 --check     # union == full, pairwise disjoint
tools/section_plan.sh --shards 3 --shard 2   # that shard's plan line
EIGS_SUITE_SHARD=2/3 bash tests/run_all_tests.sh
```

The aggregator `asan + ubsan (full suite)` — a ruleset-required check (see
**Platform tiers**), and still that name — checks everything no shard can do for itself: it
requires every matrix leg green, re-runs `--shards 3 --check`, requires one
**receipt** per shard carrying that shard's `PLAN: shard=k/3 …` line, **sums the LeakSanitizer tallies and requires 0**,
and requires exactly one claimant for each job-level ASan extra. Splitting the job must not
split the gate.

### The two ASan checks that are not suite sections

`gc_traversal_check.py --variant asan-http` and the LSP behaviour test are job-level
steps, not sections, so somebody has to own them — and "it runs somewhere" is
how a check goes missing when a job is split. They were pinned to shard 1,
which is **by construction the heaviest shard**, so they landed on the critical
path every time: on run 35036548663 shard 1 was 14.1 min of a 15.0 min lane.

Both owners are **derived** now, and printed by the step that asks:

- the collector check (5 s) goes to the **lightest** shard by predicted weight
  (`tools/section_plan.sh --shard-owner 3`);
- the LSP behaviour test goes to **whichever shard runs section [88]**
  (`--shard-owner 3 --section '[88]'`), and that is not a preference. [88]
  builds `eigenlsp` under ASan through `tests/aux_binary.sh`, so on that shard
  the step is a no-op rebuild. Measured: **1.5 s** on run 35020270020, where
  shard 1 happened to carry [88] — and **267 s** on run 35036548663, where the
  CI-measured weights had moved [88] to shard 3 and shard 1 had to build
  `eigenlsp` from scratch. Same step, same code, 180× apart.

Each shard's receipt records which extras it claimed, and the aggregator
requires **exactly one** claimant for each. A derived owner that nobody turns
out to be is the one failure hard-wiring could not have, so it is gated.

### The weights table

Balancing by section **count** would be useless: section costs span three
orders of magnitude. The runner therefore prints one line per section,

```
SECTION_TIME: [99u] 41.20
```

and `tests/section_weights.txt` is those numbers.

**Measure them on the RUNNER, not on the dev box.** The first table was a
dev-box measurement and it did not transfer: per-section ratios reach 35× in
*both* directions (`[0a]` 0.75 s dev → 26.12 CI; `[126]` 0.97 → 28.61; `[88]`
1.56 → 30.24; but `[124]` 94.87 → 13.30 and `[99o]` 21.79 → 2.41), and shards
predicted at 590/590/590 s actually took 411/249/196. A dev-box run is a
bootstrap for the very first split; the table itself comes from CI.

Refresh it from the shard job logs of any green run:

```bash
run=RUN_ID                           # a current HTTP+model shard run
head=HEAD_SHA
gh api repos/InauguralSystems/EigenScript/actions/runs/$run/jobs \
  --jq '.jobs[] | select(.name | startswith("asan + ubsan / shard ")) | .id' \
  | while read -r id; do
      gh api repos/InauguralSystems/EigenScript/actions/jobs/$id/logs
    done > /tmp/asan-shards.log
tools/section_plan.sh --print-weights /tmp/asan-shards.log \
    --run "$run" --head "$head" > tests/section_weights.txt
```

`--run` and `--head` put provenance into the file. Review the resulting table
and commit it with the new measurement; historical tables retain their
original run IDs.
Without provenance flags the header says "PROVENANCE NOT STATED".

`--print-weights` accepts the raw job log — it tolerates the ISO timestamp
prefix GitHub puts on every line, so there is no hand-stripping step to get
wrong — and sums duplicate labels, so concatenating all three shard logs is
the right input.

The split is longest-processing-time greedy over (weight desc, chunk start asc)
— **deterministic**, so CI never depends on runner timing. A section missing
from the table takes a default weight and is **reported** (`unmeasured-sections=N`,
with the roster printed), so a new section cannot silently unbalance a shard.

## [99i]: one flags home and a compiler guard

`tools/werror_flags.txt` holds the warning-error flags. The Makefile
reads it into `WERROR_FLAGS` and puts it in `CFLAGS` and every variant flag
bundle, including those consumed by Python build checks. Recipes using a
bundle do not repeat it; direct recipes add it once. Shell scripts source
`tools/read_werror_flags.sh`, which refuses a missing, unreadable or empty
home before compiling. The suite runner resolves the home from `TESTS_DIR`,
including when a section plan executes a copy under `/tmp`.

`tools/werror_switch_check.sh` checks only static properties: the exact home,
no literal copies in tracked build files, and no absolute compiler path that
bypasses the guard. It uses Git's explicit safe-directory setting in CI.
The required `werror audit` job and suite section [99i] run this small check
directly; there is no cache.

CI prepends `tools/cc-guard-bin` to `PATH` in each compiling job. The linked
`gcc`, `cc`, `clang` and `emcc` wrappers inspect the actual argv of every C
compile, reject a missing trio flag, and then execute the first real compiler
later on `PATH`. Each job requires a nonzero `CC_GUARD_LOG` count. This
compiler boundary covers commands assembled by Make, shell, Python and suite
children without guessing their source syntax. `make lsp` generates both LSP
index headers and compiles `eigenlsp.c` with the trio in its flag bundle.

## Platform tiers — what blocks a merge, and what decides main's colour (#1264)

Main CI did not finish green from 2026-09-16 to 2026-09-22 although every
required check passed on every merge: one lane that no pull request had to pass
(`macos / macos-15-intel`, main lane only) hit its timeout on nearly every
push. The README badge is the status of the whole `ci.yml` workflow on `main`,
so **any** `ci.yml` job that can fail there colours it, required or not.

The fix copies Rust (tiers plus a merge queue), CPython and Go:

- **Tier 1** — the checks listed in `.github/required-checks.txt`. They block
  a merge, and they are evaluated **in the merge queue**.
- **The merge queue.** A PR that passed the fast PR lane joins GitHub's merge
  queue. The queue builds a candidate commit (current `main` + the PRs queued
  ahead of it + this PR) and runs the **full main lane** on it (the
  `merge_group` event). Nothing lands unless every required check is green
  there, so `main` is green by construction, and **contributors never rebase
  just to update a PR** — the queue tests the combination for them. Every
  workflow that produces a required check (`ci.yml`, `codeql.yml`,
  `pages.yml`) triggers on `merge_group`, and every main-lane-only step is
  gated `github.event_name != 'pull_request'` (true on push *and* in the
  queue), never `== 'push'`.
- **The post-merge push run** re-tests the commit the queue already tested. It
  stays: the README badge reads it, it publishes the rolling `ci-main` dev
  image that fork PRs run in, and `pages.yml` deploys the site only on push
  (never from a queue candidate that may still be rejected).
- **Tier 2** — slow and port lanes, in `.github/workflows/nightly.yml`
  (today `macos-15-intel` and the full valgrind corpus). They never colour
  `main`; a failure opens or appends to one tracking issue.

### The source of truth: `.github/required-checks.txt`

One exact check-run name per line; a line starting with `#` is a comment giving
the reason for a non-obvious entry. The ruleset **"Protection"**
(`~DEFAULT_BRANCH`) is synced *from* this file, never edited by hand. To change
tier 1: edit the file in a PR, merge, and the orchestrator syncs the ruleset;
`bash tools/ci_tier_check.sh --live` (read-only) then prints OK. Between merge
and sync it names the drift — expected, which is why CI does not run `--live`.

### What `tools/ci_tier_check.sh` enforces

Only what the queue cannot guarantee by itself. It runs in the `gate
self-tests` job; its calibration runs when its inputs change or nightly. A missing PyYAML is exit 2, never a pass.

- `[unproduced]` / `[ambiguous]` — a required name is produced by no job, or by
  more than one.
- `[not-on-pr]` / `[not-in-queue]` — the producing workflow does not trigger on
  `pull_request` to `main` (or is path-filtered), or does not trigger on
  `merge_group`. Either way the check never *reports* there, and a required
  check that never reports blocks every merge until someone overrides it.
- `[event-condition]` — on a required path (a required job, the jobs it
  transitively needs, and the `ci.yml` workers), a condition could run work on
  push that the queue skips. A job-level `if:` may not mention the event at
  all: a job **skipped** by its `if:` reports a *satisfied* required check, so a
  job-level event filter lets a merge through untested. A step `if:` may
  mention the event only as `github.event_name ==/!= 'pull_request'`, or via
  the PR payload `github.event.pull_request.*` (empty on push and in the
  queue alike). Dot and bracket syntax are both read. The same rule covers
  indirection: an `env`, job `outputs`, workflow `env` or matrix value on a
  required path may not read the event (outside those two forms), and an
  `if:` that reads `env.*`, `needs.*.outputs` or `steps.*.outputs` is traced
  to where the value is set — unresolvable is red, `vars.*` is always red.
  Two reviewed step outputs are waived by a hash of their step (`scope`/`detect`
  for docs-only classification and `gate-selftests`/`select` for changed-gate
  selection); a waiver that matches nothing is red.
- `[continue-on-error]` — a job or step on a required path sets it, so its
  failure would not fail the check.
- `[uncovered]` — a `ci.yml` job is neither required nor the worker of exactly
  one required `if: always()` aggregator. A failing non-required job does not
  stop the queue, yet it colours the badge: the `macos-15-intel` shape.

Whether an aggregator's script really fails on every non-success worker
result is a code-review question, not this gate's. The gate's other accepted
limits (matrix `include`/`exclude`, expressions inside `run:` scripts,
`schedule:` triggers) are listed in #1278.

### Every `ci.yml` job, classified

| Job (check name) | Tier | Why |
|---|---|---|
| `scope` | 1 | decides docs-only; the runtime legs read its output |
| `build dev/ci image` | 1 | the image every `container:` job (the Linux legs, the extension/ASan workers, db, the audits, the differentials, freestanding) runs inside; required because required jobs `needs` it, and a failed prerequisite *skips* them — added by #1264 |
| `werror audit ([99i], cached)` | 1 | gate; name retained until the required-checks ruleset is renamed |
| `gate self-tests (section plan + audit cache key)` | 1 | gate; name retained until the required-checks ruleset is renamed |
| `linux / gcc` | 1 | full suite on every code event |
| `linux / clang` | 1 | clang `-Werror` build and full suite on every code event |
| `macos / macos-latest` | 1 | the one macOS leg; full suite with [99i] on the main lane |
| `extensions (http+model+gfx suite; embed/lsp/jit-smoke)` | 1 | **aggregator** |
| `extensions / http+model and ancillary checks`, `/ gfx suite`, `/ zlib suite`, `/ net suite` | 1, via the aggregator | workers |
| `asan + ubsan (full suite)` | 1 | **aggregator**; also re-derives shard coverage and sums the leak tally |
| `asan + ubsan / shard k/3 (http+model build)` | 1, via the aggregator | workers |
| `db extension (postgres service)` | 1 | gate |
| `jit differential (…)`, `replay differential (…)` | 1 | gates |
| `freestanding profile (symbol gate + smoke)` | 1 | gate |
| `valgrind (memcheck smoke, JIT off)` | 1 | the smoke spread (the full corpus is tier 2) |
| `tsan (concurrency race gate)` | 1 | gate |
| `install.sh (interpreter + eigenlsp on PATH)` | 1 | gate |
| `bench (instruction-count regression gate)` | 1 | gate (baseline: `origin/main` on a PR; the candidate's `merge_group.base_sha` in the queue, so a PR is never charged for the PRs queued ahead of it) |
| `nightly / macos-15-intel full suite` | **2** (`nightly.yml`) | port lane, slow: hit its timeout on nearly every main push (#1265) |
| `nightly / gate self-tests` | **2** (`nightly.yml`) | calibrates every checker |
| `nightly / valgrind (full corpus, JIT off)` | **2** (`nightly.yml`) | slow; the PR and main lanes run the smoke spread |

No `ci.yml` job moved to nightly in #1264 beyond `macos-15-intel` (#1265):
every other job already runs on pull requests, so each was made tier 1.

### Checks from other workflows

They do not affect the `ci.yml` badge. Each is required or advisory by the same
file:

| Check (workflow) | Tier | Why |
|---|---|---|
| `Analyze C` (`codeql.yml`) | 1 | runs on every PR to `main` and in the queue, no path filter |
| `playground (real emcc wasm32 build)` (`pages.yml`) | 1 | **aggregator** over `playground / build (…)`; reports on every PR and in the queue |
| `playground / build (real emcc, web/build.sh) + docs site` (`pages.yml`) | advisory | the worker; required through the aggregator |
| `deploy` (`pages.yml`) | advisory | runs only on push and `workflow_dispatch` — it publishes, it does not test |
| `codspeed (simulation)` (`codspeed.yml`), and the CodSpeed app's `CodSpeed Performance Analysis` | advisory | path-filtered (`paths-ignore: '**.md'`), so it never reports on a docs-only PR; the instruction-count gate that blocks is `bench` |
| `build` (`docker.yml`) | advisory | runs on push to `main`, `v*` tags and `workflow_dispatch`, never on a PR |
| `Scorecard analysis` (`scorecard.yml`) | advisory | runs on push, schedule and `branch_protection_rule`, never on a PR; a posture score |
| `Analyze (python)`, `Analyze (javascript-typescript)` | advisory | CodeQL *default setup* (a GitHub app, not a workflow file) over the repo's non-C code; the C analysis that blocks is `Analyze C` |
| `issue-triage / …` (`issue-triage.yml`), `release.yml` jobs | advisory | not triggered by PRs or pushes to `main` |

## Coverage on pull requests

Every built variant runs the complete suite on the PR. The HTTP+model ASan
workers partition that complete suite, and the required aggregator checks
their coverage and leak tally before the PR can merge.

## Gate self-tests on change (#1275)

The suite runs each gate's live check; `tools/selftests.sh --changed origin/main`
runs checker self-tests whose scripts, fixtures or helpers changed, including
uncommitted and untracked files, and `make precheck` includes that selection.
The required `gate self-tests (section plan + audit cache key)` check uses the
PR base SHA or merge-group base SHA, while nightly runs `tools/selftests.sh --all`
and reports failures through its tracking issue.
`tools/selftests.txt` owns the trigger globs, bounded commands and existing
result pins; changing it or the driver selects every row.

## Before you push: `make precheck` (#1264)

`make precheck` (`tools/precheck.sh`) runs the static gates — the ones that
need no suite run — plus changed-gate self-tests, exit 1 on any failure; the docs-claims gate
joins when a binary exists. Its gate list is the only copy: the
`gate-selftests` CI job runs the same script. Among them,
`tools/enrolment_check.sh` (also suite `[99ab]`) fails when a `tests/*.sh` or
`tests/*.py` is invoked by no suite section, workflow step or enrolled script;
exceptions live in `tests/enrolment_exemptions.txt` with a reason each.
Counts that grow with the suite (child-script sites, doc-claim populations)
are floors: adding a test needs no count edit, a drop is red.
