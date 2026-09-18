# CI: what runs on your PR, what runs on main, what runs nightly

Continuous integration here has three lanes. This page says which gate lives
where, why, and what a contributor should expect to wait for. It exists because
the answer stopped being "everything, everywhere" in #1160.

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

1. **The same ~263-section suite ran in TEN jobs** — gcc, clang, zlib, net,
   gfx, http, db, asan-core, asan-http, two macOS — differing only in the
   extension surface of the binary they built. A zlib build has exactly one
   section the gcc build does not; it paid for all of them.
2. **Section [99i] ran inside every one of those ten.** It is the `-Werror`
   compile-line audit: dry runs of every make target, a scan of every tracked
   shell script, and a planted-fault self-test. On the dev box that is ~6
   minutes of audit plus ~11 minutes of self-test — for a property of the
   Makefile and the scripts that cannot depend on which extensions were
   compiled in.

## PR lane (`pull_request`) — target ≤ 15 minutes

- `scope` decides whether the PR touches anything but `*.md`. A docs-only PR
  reports green in seconds. (The doc gates themselves are not skipped — see
  **The doc gates** below.)
- **One full suite: `linux / gcc`.** All ~263 sections.
- **`werror audit`** runs [99i] once, cached (see below). The suite jobs set
  `EIGS_SKIP_WERROR_AUDIT=1`, and [99i] then prints a `SKIP:` line naming this
  job — it never silently disappears.
- **Variant jobs run only the sections their binary unlocks.** zlib, net, gfx,
  http+model, the postgres `full` build and `asan-http` each run a *derived*
  section plan (below), not the whole suite.
- **`linux / clang` runs the derived core smoke.** The value of that leg on a
  PR is the build — `-Werror` fires at compile time and clang's codegen differs
  — not a tenth execution of sections the gcc leg just ran on the same commit.
- **macOS: `macos-latest` only**, and only when `scope.code` is true.
  `macos-15-intel` is not on this lane.
- Fast gates unchanged: jit differential, replay differential, freestanding,
  tsan, install smoke, bench, CodeQL, `gate self-tests`.

## The doc gates — where they run, and why they are cheap

Three sections, all on the linux legs of the PR lane. None of them builds
anything of its own, so a docs PR pays seconds, not minutes.

| Section | Tool | What it refuses |
|---|---|---|
| **[89]** | `tests/test_doc_examples.py` | an eigenscript fence that is not executed. Opt-OUT: paired with an `output` block (byte-compared), tagged `eigenscript fragment k=v ...` (free names declared in the tag, resolved STATICALLY through `--lint` E003 so a name hiding in a dead branch still counts, then run and required to finish clean), or tagged `eigenscript nocheck <reason>`. Anything else is red. It also refuses a **value stated in a comment** inside an executed example — that is a claim wearing a checked example's clothes. Per-file populations are pinned and cross-checked against an independent line scan. |
| **[99za]** | `tools/docs_claims_check.sh` | a hand-typed number, a dangling repo path **or Markdown link target** (resolved against the LINKING FILE's directory only — no repo-root fallback, because a link that resolves only at the root is a broken link). A path is classified before it is checked: `git ls-files` says SOURCE (must be tracked and present), `make -p` says BUILD PRODUCT (must be produced by a rule; its **existence is never consulted**, so `make lsp` cannot change the verdict), neither is red, **any** `--flag` token not in `--help`, a `make <target>` that is not a rule, a backticked `name of` call that resolves nowhere. Each is derived from the tree or waived by its exact line content with a reason. Every class carries a DECLARED per-file count (found == declared, both ways), and a waiver that matches nothing is red — so a claim cannot be deleted, and coverage cannot shrink, without a failure. Three rules bought on macOS: **no scan that feeds a population suppresses its stderr** (a rejected pattern used to read as "nothing found"); the **fence count comes from `tests/test_doc_examples.py --count`**, the gate that executes the fences — one grammar, not two; and **nothing in the tool extracts with `grep -o`** — grep finds lines, POSIX awk `match()`/`RSTART`/`RLENGTH` extracts, because `grep -o` is not in POSIX and GNU and BSD differ on it. A scan that matches ZERO times where a count is declared is a RED **at the scan**, quoting the command and its exit status, not a "was never visited" three hundred lines later. And the gate prints a **per-class summary LAST** — examined count, files recorded, declared rows — so a class that silently did not run is one named line rather than six consequence-REDs; the runner prints the gate's **entire** captured output on failure (bounded at 500 lines, and when that bites it keeps the first 250 AND the last 250, never a bare tail). The **binary-size** claim is measured against whichever install-shaped binary the lane actually has, decided by inode: `build/release/eigenscript` if present, else `src/eigenscript` when no `build/*/eigenscript` shares its inode (the `./build.sh` product, which is what every CI leg builds and what `install.sh` installs); a `src/eigenscript` that IS a variant alias, or a non-Linux lane, defers with the reason named and the deferral count pinned. |
| **[99zb]** | `tools/portability_parse_check.sh` | a tracked `*.sh` that the OLDEST bash on the machine cannot parse — **or a shell gate it cannot RUN**. macOS ships **bash 3.2 (2007)**, and three CI rounds were spent guessing at what it rejects — twice wrongly. The dev box now carries a real one at **`~/.local/bin/bash32`**, built from GNU bash 3.2.0 source with `./configure --without-bash-malloc --disable-nls && make` (~4 min); `bash32 -n <file>` settles any portability question in a second, and the whole repo in under two. Parsing was never enough: bash 3.2 scans `<( … )` for its closing paren **without honouring comments**, so an apostrophe in a comment inside one opens a quote that never closes — at RUNTIME, which `bash -n` calls clean. That kept the macOS lane red for four rounds. The audit therefore also EXECUTES five tracked shell gates (`docs_claims_check.sh`, `child_exit_check.sh`, `suite_label_check.sh`, `doc_drift_check.sh`, and `tests/test_string_scaling.sh --selftest` — the one `tests/` entry, eleven stub-driven cases of string-splitting bash in 0.3 s) under the old bash and requires rc 0, with the run count pinned. `PORTABILITY_RUN_SELFTEST=1` adds the claims selftest (~3 min, driver-only extra coverage — its children still spawn through `#!/usr/bin/env bash`). When no old bash is present the check **announces the skip and prints both counts**, so it can never read as a completed audit. 121 files parsed + 5 gates run, ~24 s. |
**`make -p` across make versions — measured, not assumed.** macOS runners carry
**GNU Make 3.81** (2006); this box has 4.3, and [99za]'s build-product
classifier parses `make -p -n --no-builtin-rules`. That was the leading
suspicion for the macOS PATHS failure, so it was tested rather than guessed at:
GNU Make 3.81 built from source (`curl -O
https://ftp.gnu.org/gnu/make/make-3.81.tar.gz`, `./configure`, then
`make GLOBINC= GLOBLIB= CFLAGS=-O2` — the bundled `glob/` does not link against
modern glibc, the system one does; ~90 s) produces, over this Makefile,
**exactly the same 886 file targets and the same 898-entry producer set** as
4.3. The only difference in the variable dump is `MAKE_HOST`, which no recipe
uses. So the database parse is version-stable here and `make -p` is **not** the
macOS cause. The tool still reports its two routes separately and falls back to
the Makefile's own `^VAR := value` lines if a database ever yields none — but
that is insurance, not a fix for a diagnosis.

**The gate's output is deterministic, and that is a checked property.** A
selftest row runs the gate twice — once with build products absent, once with
them present — and requires the two outputs to be BYTE-IDENTICAL, because a
verdict that moves with build state is a verdict that depends on what someone
ran. That row failed on macOS for four rounds, and the cause was not build
state at all: under **bash 3.2** a `printf … | grep -q` (or `| head -1`, or
`| awk '… exit'`) makes the shell's own `printf` builtin take SIGPIPE when the
reader exits first, and 3.2 PRINTS `printf: write error: Broken pipe` where
bash 5 swallows it — nondeterministically, because it is a race. Every
early-exiting reader in the gate is now fed by a **here-string** instead of a
pipe (a here-string is a temp file; there is no pipe to break). Same family as
`tools/pipefail_verdict_check.sh` (#1122).

| **[99v]** | `tools/doc_drift_check.sh` | the staleness classes that are not numbers: a stdlib module with no `docs/STDLIB.md` entry, a stale "Latest release" line, a `VERSION` with no CHANGELOG section, an unstamped `docs/llms.txt`. |

Both new gates carry a planted-fault selftest that the suite runs with a
**pinned case count** — `--selftest` on each tool, 29 and 36 cases — so a
selftest reduced to an echo is red, not green. Cost on the dev box, measured: [89]
runs 180 example programs plus a `--lint` pass each in **3 s**; [99za]'s live
pass is **4 s** (one `git ls-files`, one `make -p -n`, one `--api`, one
`--help`, one `suite_label_check.sh`, one `lib/ui.eigs` load, one
`test_doc_examples.py --count`) and its 36-case selftest is **~3 min**,
because each case re-runs the whole gate through its public entry point and
nine of them copy the tree to vary build state. That
scratch copy is made NEXT TO the repo, not in `/tmp`: a hard link cannot cross a
filesystem, and on a CI runner the workspace and `/tmp` are different mounts. Both belong on the PR lane; neither belongs nightly.

To add a document to [89]: add it to `DOC_FILES_ARG` in the runner AND a row to
`POPULATION` in `tests/test_doc_examples.py`, and bump `DOC_POPULATIONS`. The
checker refuses a document that carries fences and has no pinned row, and the
suite refuses a run that covered fewer rows than are pinned — a file quietly
dropped from either list is a failure at both ends.

## Main lane (push to `main`) — the full matrix

Everything above runs in full: both macOS runners, every variant job on the
complete suite, `linux / clang` on the complete suite. The only thing that does
not run ten times is [99i], which the `werror audit` job owns.

This is the real exit gate. #1138 and #1158 both carried lanes only CI could
run. Contributors never wait on it; whoever merges does.

## Nightly (`.github/workflows/nightly.yml`)

- `macos-15-intel`, the full suite — the 35-minute job that used to set the PR
  wall clock. Intel-mac-only shapes are real; they can lag a day.
- **valgrind over the whole runnable corpus**, not the fixed smoke spread
  (`tests/valgrind_smoke.sh --full`). This is the ONLY lane that runs the full
  corpus: both the PR lane and `main` run the smoke spread. The spread's size
  is not written down anywhere — `valgrind_smoke.sh` prints `programs=<n>` from
  `${#PROGS[@]}`, because the last three documents that hard-coded it said 28
  when the list held 27.
- A failure opens — or appends to — a single tracking issue, so a nightly that
  nobody is watching still reaches someone. A green run after a red one
  comments on the same thread, which is what makes the thread closable.

## How a variant job knows which sections to run

`tools/section_plan.sh`. Nothing here is hand-listed:

1. It splits `tests/run_all_tests.sh` into top-level **chunks**, asking `bash
   -n` where a top-level statement ends, and verifies that preamble + chunks +
   epilogue reconstructs the file byte-for-byte. A boundary bug therefore
   cannot silently drop sections.
2. Every capability gate in the suite **declares itself** with a one-line
   marker, `# EIGS-CAP-GATE: <capability>`. That is the normalised spelling:
   the suite's gates are not all written the same way, and a parser that knew
   only the `<NAME>_PROBE_OUT` block silently dropped four of them — `[97]`
   (an inline `EX_HAS_GFX` probe), `[138]` and `[139]` (children that self-skip
   with "built without EIGENSCRIPT_EXT_GFX") and `[42a]` (a child that gates
   only its audio-capture replay checks).
   The marker population is pinned against an **independent enumeration**:
   `grep -nE 'ndefined variable|compiled without zlib|built without|no gfx
   build'` over the runner and over every child script the runner dispatches
   (the child list itself derived from the runner). Every hit must be inside a
   marked chunk, dispatched from one, or named in a content-pinned waiver with
   a reason — and a waiver that matches nothing is a hard failure too. So a new
   gate spelling cannot enter the tree silently; it fails the audit.
   A waiver pins the **exact line**, by content hash, not a substring: a
   substring waiver let a real capability gate planted into an already-waived
   file inherit a reason that was false for it. When the audit reports
   unaccounted lines, `tools/section_plan.sh --gate-audit --print-waivers`
   prints paste-ready rows for them and writes nothing — the reason is a
   reviewer's to add.
3. It **runs each probe program against the binary under test** and applies the
   suite's own predicate. The plan is exactly "the sections this binary
   unlocks", plus a small fixed core smoke.
4. It floors the result. Every probe-idiom chunk must carry a marker and every
   declared capability must have at least one probe provider (there is no
   standalone probe-count floor — the number of providers is not an independent
   fact); each
   variant has a floor on how many capabilities its binary must actually
   present. A `make http` whose `http_route` registration broke still builds
   and still runs — and its plan collapses to the core smoke, which the floor
   turns red instead of green.

Useful locally:

```bash
tools/section_plan.sh --markers                    # the declared capability gates
tools/section_plan.sh --gate-audit                 # the marker population, pinned
tools/section_plan.sh --probes                     # the derived probe table
tools/section_plan.sh --print-section-plan zlib    # the plan, counts, floors
tools/section_plan.sh --selftest                   # the planted-fault train
EIGS_SUITE_SECTIONS=zlib bash tests/run_all_tests.sh   # run that plan
```

`--selftest` takes about **7.5 minutes** on the dev box — six of its rows
re-derive the 429-chunk table at ~15 s each — so it is a "before you push"
check, not an inner-loop one. It runs on every CI run in `gate self-tests`.

Every plan run prints one line, and the runner CHECKS it: after the plan runs,
the dispatcher counts the `[...]` section headers the run actually printed and
fails if that differs from the number the plan promised. `sections=` counts the
headers that will EXECUTE — a probe gate's else-branch twin
(`… SKIPPED (binary built without …)`) never runs on a binary that has the
capability, and counting it made round 1 promise 18 for a run that printed 16.

```
SECTION PLAN: PLAN: sections=6 (of 263) chunks=5 plan=zlib capabilities=1 (floor 1) gated-chunks=1 (floor 1)
```

A plan of zero sections is a hard failure, and so is a RUN of zero assertions:
`RESULTS: 0/0 passed, 0 failed` used to exit 0, which is indistinguishable from
a clean run.

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

That job stays **full** on purpose: it is the leak-tally gate (CLAUDE.md, "the
suite must pass both release and ASan with leaks on"). So it runs in parallel
shards instead. With ~2 min of queue and a 4.7-min ASan build in front,
`queue + build + 13.9/N` gives 20.6 / 13.7 / **11.3** / 10.2 for N = 1/2/3/4.
N=2 clears 15 by 1.3 min, which is inside runner noise; N=3 clears it by 3.7;
past N=3 the *build* dominates and a fourth shard buys 1.1 min for another 4.7
build-minutes. **N = 3.**

**MEASURED: 13.4 min wall on run 35020270020 (head c4c23ae), then 15.0 min on
run 35036548663 (head 418d62d) — 35 → 21.1 → 13.4 → 15.0.** The regression was
not the split: the runner-measured weights worked, and the three suite steps
came in at 290 / 285 / 278 s against a predicted 319 / 272 / 272. It was the
job-level LSP step, hard-wired to shard 1, jumping from 1.5 s to 267 s (see
below). With both extras' owners derived, the predicted lane is **~11.5–12.5
min**, with the critical path moving off shard 1.

The floor is now one section, not the arithmetic: `[137]` (the ext_gfx
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

The aggregator `asan + ubsan (full suite)` — still the only ruleset-required
check, and still that name — does four things no shard can do for itself: it
requires every matrix leg green, re-runs `--shards 3 --check`, requires one
**receipt** per shard carrying that shard's `PLAN: shard=k/3 …` line, and
**sums the LeakSanitizer tallies and requires 0**. Splitting the job must not
split the gate.

### The two ASan checks that are not suite sections

`gc_traversal_check.py --variant asan` and the LSP behaviour test are job-level
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
run=35020270020                     # the CI run id
gh api repos/InauguralSystems/EigenScript/actions/runs/$run/jobs \
  --jq '.jobs[] | select(.name | startswith("asan + ubsan / core and LSP")) | .id' \
  | while read -r id; do
      gh api repos/InauguralSystems/EigenScript/actions/jobs/$id/logs
    done > /tmp/asan-shards.log
tools/section_plan.sh --print-weights /tmp/asan-shards.log \
    --run "$run" --head c4c23ae > tests/section_weights.txt
```

`--run` and `--head` are what put the provenance INTO the file, so the command
above reproduces the committed `tests/section_weights.txt` **byte-for-byte** —
`diff` it, that is the check. Without them the header says so, loudly
("PROVENANCE NOT STATED"): a table whose origin the regeneration step erases is
a table nobody can check.

`--print-weights` accepts the raw job log — it tolerates the ISO timestamp
prefix GitHub puts on every line, so there is no hand-stripping step to get
wrong — and sums duplicate labels, so concatenating all three shard logs is
the right input.

The split is longest-processing-time greedy over (weight desc, chunk start asc)
— **deterministic**, so CI never depends on runner timing. A section missing
from the table takes a default weight and is **reported** (`unmeasured-sections=N`,
with the roster printed), so a new section cannot silently unbalance a shard.

## The [99i] cache

`tools/werror_cache_key.sh` hashes:

- the **content** of `Makefile` and of every tracked `*.sh` (the audit scans
  all of them, and the audit's own source is one of them);
- the **names** of tracked files under `src/ tests/ tools/ web/ fuzz/`, because
  adding a source file changes the compile lines even though no covered file's
  content moved.

It deliberately does not cover `.c`/`.h` content or docs: those cannot change a
compile *invocation*, and hashing them would miss the cache on every
documentation PR — the contributor wait this change exists to remove.

`tools/werror_cache_key.sh --selftest` carries both halves of the control: a
one-line `Makefile` edit **misses** the cache, a docs-only edit **hits** it.

**The gate is split, and that split is what makes the exclusion sound.**
`tools/werror_switch_check.sh` also runs the two LSP index generators, and
`gen_lsp_builtin_index.sh` reads reserved observer words out of `src/lexer.c`.
A blind critic planted `return TOK_REPORT;` → `return (TOK_REPORT);` there: the
audit failed ("could not regenerate builtin LSP index") behind a byte-identical
key. So CI runs `--headers-only` (0.5 s, the generator probes) **uncached on
every run**, and caches only `--no-headers` (the dry runs and script scans,
whose inputs really are the Makefile and the tracked scripts). A local
`bash tools/werror_switch_check.sh` with no flag still runs both halves, and so
does the suite's [99i]. `werror_cache_key.sh --selftest` reads both `ci.yml`
and the audit script and fails if the split stops being used.

## Required status checks — what is actually required today

Read off the live repo (`gh api repos/InauguralSystems/EigenScript/rulesets`,
2026-09-15), because round 1 of this change documented a list that does not
exist:

- Classic branch protection on `main`: **not enabled** (`branches/main/protection`
  returns 404, "Branch not protected").
- Ruleset **"Protection"** (active, `~DEFAULT_BRANCH`) requires exactly **one**
  status check: `asan + ubsan (full suite)`.
- Ruleset **"Main"** (active) targets `refs/heads/Main` — a branch with a
  capital M that does not exist — and requires `Black`. It is inert.

So `macos / macos-15-intel` was never in a required list, and nothing here
"must be removed" for the merge to work. What matters instead is the reverse:
**`asan + ubsan (full suite)` is the only gate the ruleset enforces**, and it
is an *aggregator* — it reports success only when both sanitizer workers
succeed (see below). That single rule keeps working unchanged under this
change.

### The PR-lane job set, and which are aggregators

On a pull request, `ci.yml` produces these checks:

| Check | Kind |
|---|---|
| `scope` | gate; decides docs-only |
| `build dev/ci image` | prerequisite; every Linux leg runs inside it |
| `werror audit ([99i], cached)` | gate |
| `gate self-tests (section plan + audit cache key)` | gate |
| `linux / gcc` | the one full suite |
| `linux / clang` | build + derived core smoke |
| `macos / macos-latest` | full suite (code PRs only) |
| `extensions (http+model+gfx suite; embed/lsp/jit-smoke)` | **aggregator** over the four workers below |
| `extensions / http+model and ancillary checks` | worker |
| `extensions / gfx suite` | worker |
| `extensions / zlib suite` | worker |
| `extensions / net suite` | worker |
| `asan + ubsan (full suite)` | **aggregator** over the two workers below |
| `asan + ubsan / core and LSP` | worker |
| `asan + ubsan / HTTP and model suite` | worker |
| `db extension (postgres service)` | gate |
| `jit differential (interpreter oracle, tape-replayed)` | gate |
| `replay differential (same-binary tape fidelity)` | gate |
| `freestanding profile (symbol gate + smoke)` | gate |
| `valgrind (memcheck smoke, JIT off)` | gate (the smoke spread; the job prints its size) |
| `tsan (concurrency race gate)` | gate |
| `install.sh (interpreter + eigenlsp on PATH)` | gate |
| `bench (instruction-count regression gate)` | gate |
| `Analyze C` (workflow `CodeQL`) | gate, separate workflow |

`macos / macos-15-intel` appears **only** on a push to `main`, and nightly.

An aggregator exists so that a *required* check name can survive the job being
split into parallel workers: it fails unless every worker succeeded, and it
treats `skipped`, `cancelled` and missing results as failure. A worker is not
separately required; it is required *through* its aggregator.

### If the required set is ever widened

The set worth requiring, if someone tightens the ruleset, is: `scope`,
`linux / gcc`, `extensions (…)`, `asan + ubsan (full suite)`,
`db extension (postgres service)`, `macos / macos-latest`,
`werror audit ([99i], cached)`, `gate self-tests (…)`, the two differentials,
`freestanding`, `tsan`, `install.sh`, `bench`, `valgrind` and `Analyze C`.
**Never** `macos / macos-15-intel`: it does not run on pull requests, and a
required check that never reports blocks the merge forever — the same trap the
`scope` job's comment in `ci.yml` describes.

## The risk this accepts

A variant-specific regression in a *non-variant* section reaches `main` before
anything catches it — for example a clang-only miscompile in a section the
core-smoke plan does not cover. Main runs the full matrix before anything is
released, so the window is between merge and the next main run, and nothing
ships through it. That trade is deliberate: it buys back roughly half the
machine-minutes and more than half the contributor wait.
