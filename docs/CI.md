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
  reports green in seconds. (The doc gates themselves are not skipped: the
  executable `docs/SPEC.md` / `docs/COMPARISON.md` examples run inside the
  suite on the linux legs.)
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

## Main lane (push to `main`) — the full matrix

Everything above runs in full: both macOS runners, every variant job on the
complete suite, `linux / clang` on the complete suite. The only thing that does
not run ten times is [99i], which the `werror audit` job owns.

This is the real exit gate. #1138 and #1158 both carried lanes only CI could
run. Contributors never wait on it; whoever merges does.

## Nightly (`.github/workflows/nightly.yml`)

- `macos-15-intel`, the full suite — the 35-minute job that used to set the PR
  wall clock. Intel-mac-only shapes are real; they can lag a day.
- **valgrind over the whole runnable corpus**, not the 28-program smoke
  (`tests/valgrind_smoke.sh --full`). This is the ONLY lane that runs the full
  corpus: both the PR lane and `main` run the 28-program smoke.
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
4. It floors the result. Eleven probe sites must be found in the runner; each
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
| `valgrind (memcheck smoke, JIT off)` | gate (28-program spread) |
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
