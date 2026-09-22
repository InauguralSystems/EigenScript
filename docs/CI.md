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

1. **The same suite — 263 test sections today — ran in TEN jobs** — gcc, clang, zlib, net,
   gfx, http, db, asan-core, asan-http, two macOS — differing only in the
   extension surface of the binary they built. A zlib build has exactly one
   section the gcc build does not; it paid for all of them.
2. **Section [99i] ran inside every one of those ten.** It is the `-Werror`
   compile-line audit: dry runs of every rule in the Makefile, a scan of every tracked
   shell script, and a planted-fault self-test. On the dev box that is ~6
   minutes of audit plus ~11 minutes of self-test — for a property of the
   Makefile and the scripts that cannot depend on which extensions were
   compiled in.

## PR lane (`pull_request`) — target ≤ 15 minutes

- `scope` decides whether the PR touches anything but `*.md`. A docs-only PR
  reports green in seconds. (The doc gates themselves are not skipped — see
  **The doc gates** below.)
- **One full suite: `linux / gcc`.** All 263 test sections.
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
| **[99za]** | `tools/docs_claims_check.sh` | a hand-typed number, a dangling repo path **or Markdown link target** (resolved against the LINKING FILE's directory only — no repo-root fallback, because a link that resolves only at the root is a broken link). A path is classified before it is checked: `git ls-files` says SOURCE (must be tracked and present), `make -p` says BUILD PRODUCT (must be produced by a rule; its **existence is never consulted**, so `make lsp` cannot change the verdict), neither is red, **any** `--flag` token not in `--help`, a `make <target>` that is not a rule, a backticked ``<builtin> of …`` call that resolves nowhere. Each is derived from the tree or waived by its exact line content with a reason. Every class carries a DECLARED per-file count (found == declared, both ways), and a waiver that matches nothing is red — so a claim cannot be deleted, and coverage cannot shrink, without a failure. Three rules bought on macOS: **no scan that feeds a population suppresses its stderr** (a rejected pattern used to read as "nothing found"); the **fence count comes from `tests/test_doc_examples.py --count`**, the gate that executes the fences — one grammar, not two; and **nothing in the tool extracts with `grep -o`** — grep finds lines, POSIX awk `match()`/`RSTART`/`RLENGTH` extracts, because `grep -o` is not in POSIX and GNU and BSD differ on it. A scan that matches ZERO times where a count is declared is a RED **at the scan**, quoting the command and its exit status, not a "was never visited" three hundred lines later. And the gate prints a **per-class summary LAST** — examined count, files recorded, declared rows — so a class that silently did not run is one named line rather than six consequence-REDs; the runner prints the gate's **entire** captured output on failure (bounded at a fixed line count, and when that bites it keeps the head AND the tail, never a bare tail). The **binary-size** claim is measured against whichever install-shaped binary the lane actually has, decided by inode: `build/release/eigenscript` if present, else `src/eigenscript` when no `build/*/eigenscript` shares its inode (the `./build.sh` product, which is what every CI leg builds and what `install.sh` installs); a `src/eigenscript` that IS a variant alias, or a non-Linux lane, defers with the reason named and the deferral count pinned. |
| **[99zb]** | `tools/portability_parse_check.sh` | a tracked `*.sh` that the OLDEST bash on the machine cannot parse — **or a shell gate it cannot RUN**. macOS ships **bash 3.2 (2007)**, and three CI rounds were spent guessing at what it rejects — twice wrongly. The dev box now carries a real one at **`~/.local/bin/bash32`**, built from GNU bash 3.2.0 source with `./configure --without-bash-malloc --disable-nls && make` (~4 min); `bash32 -n <file>` settles any portability question in a second, and the whole repo in under two. Parsing was never enough: bash 3.2 scans `<( … )` for its closing paren **without honouring comments**, so an apostrophe in a comment inside one opens a quote that never closes — at RUNTIME, which `bash -n` calls clean. That kept the macOS lane red for four rounds. The audit therefore also EXECUTES five tracked shell gates (`docs_claims_check.sh`, `child_exit_check.sh`, `suite_label_check.sh`, `doc_drift_check.sh`, and `tests/test_string_scaling.sh --selftest` — the one `tests/` entry, 23 stub-driven cases of string-splitting bash) under the old bash and requires rc 0, with the run count pinned. `PORTABILITY_RUN_SELFTEST=1` adds the claims selftest (~3 min, driver-only extra coverage — its children still spawn through `#!/usr/bin/env bash`). When no old bash is present the check **announces the skip and prints both counts** AND names every candidate it looked at, so it can never read as a completed audit. The file count, the gate count and the oracle are printed by the check itself (`portability: OK: files=… checked=… parse-failures=0; gates-run=…/… run-failures=0 (oracle …)`) rather than typed here, because a number typed into a page about a count that moves is a number that rots. **The system shell is a candidate when it IS old** (round-5 blind critic, Fable): until then the candidate list was `$PORTABILITY_BASH` and the two `bash32` oracle paths and nothing else, so on the one platform this audit exists for — the macOS runner, whose default `/bin/bash` IS GNU bash 3.2.57 — it found no old bash and skipped with "NO OLD BASH ON THIS MACHINE". That reason was false; the list simply never tried `/bin/bash`. `/bin/bash` and `/usr/bin/bash` are now candidates **when their own `BASH_VERSINFO[0]` is ≤ 3**, so the macOS lane runs the real audit and a Linux runner's bash 5 is never mistaken for an oracle. **Round 6: EVERY candidate is asked its own version, including the declared ones** — `$PORTABILITY_BASH` and the two `bash32` paths were trusted BY NAME, and a file called `bash32` is not bash 3.2 (a symlink to the system shell, or a rebuild that picked up a modern source), so the gate could print a truthful `oracle=… version 5.x` receipt for an audit that models nothing; a name is a hint, `BASH_VERSINFO[0]` is the fact. The skip line names every candidate it looked at AND every one it rejected by version, and those lines now reach the CI log. **The CALLER pins the identity too, and it keys on the FACT rather than the banner**: the gate prints `portability-parse: oracle-major=N` from the SELECTED candidate's own `BASH_VERSINFO[0]`, and `[99zb]` parses THAT line while holding its own `≤ 3` literal. Round 6 read the major version out of the GNU version banner instead, so a real bash 3.2 behind a wrapper whose banner says `Custom Bash 3.2.0` yielded no number at all and was failed BY NAME (round-6 blind critic, Fable) — a banner is prose, a version is a fact. A gutted selection is still red by name (`the portability gate measured under bash 5 — that is not the old shell it exists to model`) rather than passing on rc 0 and a verdict prefix. And because that arm never fires on a healthy tree, `[99zb]` now drives it over THREE SYNTHETIC RECEIPTS as its own planted faults — a bash 5 wearing a 3.2 banner must be refused, a real 3.2 with a vendor banner must be accepted, and a completed audit with no identity line must be refused — both halves of the control, judged by the same function that judges the real receipt. |
**`make -p` across GNU Make releases — measured, not assumed.** macOS runners carry
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

**The doc set every [99za] class walks, named.** `tools/docs_claims_check.sh`
examines `README.md`, `docs/llms.txt`, `CLAUDE.md`, `docs/ARCHITECTURE.md`,
`docs/BUILTINS.md`, `docs/CONCURRENCY.md`, `ROADMAP.md` and **this page**
(`DOC_FILES_DEFAULT` in the tool; the gate prints the list and the per-file
counts on every run, so the set is never something this page asserts) — and
every class, including
**BUILTIN FAMILIES** (the class that refuses a doc line naming a builtin family
`eigenscript --api` does not carry, bought by ROADMAP.md's "Raw TCP/UDP
sockets", #1227), is only as wide as that list.

`docs/CI.md` was enrolled in round 7 of #1207 (third critic,
`/code-review 1226 medium`, finding 7), because the page that tells a
contributor what runs on their PR is a front door and four of its hand-typed
numbers were already stale in the diff that wrote them. It is exempt from ONE
class, **FLAGS**, and the exemption is named in `DOC_FILES_FLAGS_EXEMPT` with
its reason: that class asks `eigenscript --help` about every `--flag` token,
and almost every `--flag` token on this page belongs to another program
(`--selftest`, `--contract`, `--paginate`, `--without-bash-malloc`, ...), so
enrolling it there would mean a waiver per line, all carrying one sentence,
and a gate whose failures are mostly noise. The gate AUDITS that exemption: every
exempt entry must exist, must be enrolled for the other four classes, and must
actually have been held out — an exemption that no longer fires is red, not
quiet.

The other documents are outside it deliberately: `docs/SPEC.md`, `docs/COMPARISON.md`, `docs/PREDICATES.md`,
`docs/OBSERVER.md`, `docs/TRACE.md` and the rest are either **executed-example
documents**, where section [89] runs every fence against the built binary and a
false claim fails as a program rather than as prose, or prose about design that
states no derived number. The cost of that boundary is exact and worth writing
down: **a builtin-family claim in `docs/TRACE.md` is unseen by [99za]** — if
`docs/TRACE.md` ever says the tape records UDP sockets, no class here will
object. Widening `DOC_FILES_DEFAULT` is the fix when that becomes real, and it
requires re-deriving every per-file declared count in the same commit.

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

## Issue labels, and the roadmap that is a milestone set

Two things that were kept by memory are now kept by a gate, both bought the
same day (2026-09-21, #1207/#1155 and the maintainer's "we aren't labeling
issues").

**Issue labels.** The scheme on the repository is `area:<subsystem>`
(runtime-vm, jit, concurrency, observer, memory, trace-tape, packages, http,
gfx, embed, docs, ci, gates, lint-tooling, consumer, aot, stdlib), a KIND
(`kind:silent-wrong`, `kind:gate-defect`, `kind:docs-drift`, `kind:flake`,
`kind:tracking`, `kind:decision`, or the stock `bug`/`enhancement`),
`found-by:*` (critic, wave, code-review, consumer, ci, cold-read) and
`blocks-release`. The rule is: **every open issue carries an `area:` label and
a kind.** `tools/issue_labels_check.sh` enumerates every open ISSUE (never a
pull request), prints `examined=N missing=M` with the offending numbers, and
fails when M > 0 **or when N == 0** — an empty enumeration satisfies "nothing
is missing" without checking anything. Without `gh` it SKIPs by name; it never
turns a missing credential into a pass. `.github/workflows/issue-triage.yml`
runs it daily and, on `issues: [opened, reopened]`, puts `needs-triage` on
anything that arrives without an `area:` label. The backlog was essentially
unlabelled before the sweep; the often-quoted "33 of 36" census is not
reproducible from the API (the open set was 35 at the sweep and never 36), so
the figure of record is whatever the gate prints on the day, not a number
copied into this page: it reports `examined=N missing=M` on every run, and the
build fails when M is not zero (or when N is zero, which is the vacuity that
"nothing is missing" would otherwise satisfy).

**One CI lane HOLDS the ROADMAP history, and `[99za]` checks that it did.**
ROADMAP.md's two pre-PR checkbox counts are derived by running
`git show <base>:ROADMAP.md` — and `actions/checkout` is shallow, so on a pull
request the merge ref's parents are absent and the base is unreachable. Both
claims therefore DEFERRED by name on every lane, on every push: measured in
this PR's own logs (`linux / gcc` job 106465168161 and `macos` job
106465087620 both printed `docs-claims: OK — NUMBERS 36
(history-deferred=2)`), so retyping 113 as 114 passed CI (third critic,
`/code-review 1226 medium`). The `linux` job now fetches that ONE commit
before the suite — `git fetch --depth=1 origin <sha>`, about a second, with
the SHA read out of `tools/docs_claims_check.sh` rather than copied into the
workflow, so there is no second home for it to drift from. `[99za]` then
PROBES the commit itself and requires `history-deferred=0` on a lane that
holds it; on a lane that does not, it prints the deferral by name. And because
a per-lane probe alone cannot notice that EVERY lane stopped holding the
history, one more check refuses a tree whose `ci.yml` no longer fetches it.
(The full 40-character SHA, not an abbreviation: `git fetch origin <sha>`
rejects an abbreviated object name outright.)

That check found a second cause on its FIRST CI run, which is the whole
argument for it. With the commit fetched and demonstrably present — the caller
read it — the gate still deferred, because the gate's `git cat-file` was PLAIN
`git` and the container runs as a different uid from the checkout's owner, so
git refuses with "detected dubious ownership" and the `2>/dev/null` made that
indistinguishable from a shallow clone. `git ls-files` in the same file, three
hundred lines away, had carried `-c safe.directory='*'` for months. One
workaround, every git call — and the caller that probes with the flag is what
makes a gate that cannot agree with it red by name.

**`gh api --paginate` returns ONE array, so the labels gate stopped splicing
one.** `issue_labels_check.sh` carried `sed 's/^\]\[/,/' | tr -d '\n'` to join
per-page arrays. Measured with `per_page=3` over four pages: `gh` merges them
itself and there is no `][` seam at all — and on a `gh` that DID concatenate
raw bodies the seam would sit mid-line, where a `^`-anchored sed cannot reach
it. A dead repair that reads as a live one is worse than none. The splice is
gone; the Python classifier accepts EITHER a merged array or an array of pages
and refuses anything else by name, with a two-page fixture whose unlabelled
issue is on the SECOND page. `--slurp` would state the shape explicitly and is
deliberately not used: `gh` 2.45.0 (Ubuntu's package, what the dev box has)
answers `unknown flag: --slurp`, which would turn the gate into a named SKIP —
red at a live caller — on every lane whose `gh` predates the flag.

**The caller holds its own copy of every pin.** Round 1 accepted the gate
gutted to `exit 0` — `exit=0 output=''` passed both boundaries — so round 2 had
each gate publish a contract (`--contract`: the population line it promises,
`POPULATION_RE`, and how many planted faults its selftest runs,
`SELFTEST_CASES`) and had both callers READ it. That made the thing being
policed supply the yardstick: `POPULATION_RE=examined=|.*` admitted empty
output, and a gate that deleted its plants and lowered `SELFTEST_CASES` passed
the daily lane. Round 3 keeps TWO copies, kept equal by a test. Each caller —
`[99zd]` in `tests/run_all_tests.sh` and the audit step in
`.github/workflows/issue-triage.yml` — holds the population regex and the
selftest case count as LITERALS, asserts the gate's output against its own
copy, and separately asserts that the gate's `--contract` equals that copy
verbatim. A difference is red by name ("gate contract changed; re-pin the
caller deliberately") and is never auto-adopted. Three consequences worth
knowing:

* the population count group is `[1-9][0-9]*` and exactly ONE matching line is
  required, so an empty enumeration and a duplicated line are both red;
* the source is a machine-readable token (`gh-api:` / `fixture:` /
  `skipped:`), because both callers used to accept `(source: fixture ...)` as a
  live measurement — their regex stopped before `(source:`. The pins admit NO
  `fixture:` source anywhere. Whether they also require a LIVE `gh-api:` token
  depends on the lane, and each caller decides that FOR ITSELF, never from the
  gate's claim: each runs the shared probe `tools/gh_probe.sh` (the same code
  the gates run), and when the probe reaches GitHub the pin requires
  `milestones=gh-api:… refs=gh-api:… resolved=N skipped=0`, a `gh-api:` labels
  line with no `SKIPPED BY NAME` alternative, and — when the caller's own
  `python3 -c 'import yaml'` succeeds — `loader=pyyaml`. When the probe does
  NOT reach GitHub the named skip is accepted and the caller prints its own
  line (`[99zd] live arms: SKIPPED (no gh credentials on this lane)`), so the
  log says which lanes measured what. Round 3 stated flatly that "the pinned
  regexes require a LIVE source token"; that was false for two of the three
  pins, which is what let a gate whose GitHub arms never ran pass on an
  authenticated box;
* each caller counts its own work. Every assertion that reached a verdict the
  caller accepts increments a witness, and a final check compares the witnesses
  and the caller's check count with pinned literals — so deleting or
  short-circuiting a check changes RESULTS instead of quietly measuring less.

A successful exit is not a measurement, and neither is a contract the gate
wrote for itself.

**A declared-but-empty token is a declared token.** Each caller cross-checks
the probe against an INDEPENDENT signal — does this lane DECLARE a credential?
— and a lane that declares one and cannot reach GitHub is red by name rather
than allowed its skip. Round 4 asked that question with `[ -n "$GH_TOKEN" ]`,
so a lane exporting `GH_TOKEN=""` declared nothing by it. That is not a
hypothetical shape: `env: GH_TOKEN: ${{ secrets.TYPO }}` exports an EMPTY
string, not nothing, and a secret that is missing, misspelled or scoped away
produces exactly it. With an empty token the probe reported
`gh-unauthenticated`, every GitHub-facing arm took its named skip, and the
suite caller's eleventh check printed "this lane declares no token" and passed
**11/11** on a lane that measured nothing (round-5 blind critic, Astra).
`gh_probe_token_declared` now tests PRESENCE (`${GH_TOKEN+x}`): an empty export
is a credential this lane was written to hold and cannot use, which is the
finding. An UNSET token — the dev box's keyring login, the macOS runner, the
sanitizer shards — is the only shape that still permits the named skip.

**What the caller can and cannot prove.** A caller verifies that a gate printed
a population line it could only have produced by running its live arm ON THIS
LANE (token-pinned, against the caller's own probe), and that the gate's
selftest ran with the pinned count. A gate that FABRICATES its own output —
printing the population line and the selftest line with no work behind them —
is outside the caller's power to detect: a forged receipt reads exactly like a
true one, and a round-4 blind critic scored 10/10 against print-only stubs. That
is what the blind-critic rounds and each gate's own transverse mutations are
for. The caller's job is to make the receipt SPECIFIC enough that forging it is
a deliberate lie about a checkable thing, not to render forgery impossible.

**Which lanes run the live arms.** `ci.yml`'s `linux / gcc` job (and `clang` on
a push) runs the full suite inside the dev image, which now installs `gh` from
a pinned, checksummed release tarball (`.devcontainer/Dockerfile`), and its
suite step exports `GH_TOKEN: ${{ github.token }}` with `issues: read` on the
job. `.github/workflows/issue-triage.yml`'s daily audit runs BOTH the labels
gate and `tools/roadmap_check.sh`, with a pin that admits no skip at all —
that lane exists to make the API call. Every other lane (macOS, the sanitizer
shards) declares no token, skips the GitHub arms BY NAME, and says so on the
caller's own line. **The sanitizer shards could hold a token and deliberately
do not**: all three run the same dev image as `linux / gcc`, so `gh` is there
and `${{ github.token }}` would work — they would simply add three more
`gh api` walks per push (a milestone read, an organisation listing and a
reference walk each) for an answer `linux / gcc` and `linux / clang` have
already produced on that same commit. The live arms are about the CONTENT of
ROADMAP.md, which is identical across shards; running them once per push is the
measurement, and running them four times is rate limit. Before round 4 no lane anywhere could do anything but skip:
the milestone mirror and the reference resolver — the whole point of #1207 —
were executed against GitHub by nothing, while `[99zd]` reported
`population lines 3/3`.

**ROADMAP.md.** `tools/roadmap_check.sh` refuses (a) any `- [ ]`/`- [x]`/`- [~]`
line anywhere in the file and anything other than exactly one table, inside
`## Milestones`, with five cells and a known status per row; and (b) — with
`gh` present and authenticated — an open table row set that differs from the
open GitHub milestones by number, or a milestone list that comes back empty.
Arm (b) also compares each open row's DONE cell with that milestone's own DONE
text (equality after whitespace normalisation — a PREFIX rule would call a
truncation green, and a truncation is what round 1 shipped for M7); and a new
arm (c) resolves every issue/PR reference in the table's cells plus every
repo-qualified reference anywhere in the file, because round 1 credited
"Tidepool PR #375" for a change that is EigenScript PR #375 and the Tidepool
endpoint 404s. Arms (b) and (c) skip by name without `gh` — and also when `gh` is
present but UNAUTHENTICATED, which is the state the macOS runner is in and
which round 2 reported as seven 404s, taking that leg red on a tree whose
references are all fine. Within arm (c), a genuine HTTP 404 is red with the
status in the message; a 401/403/429, a transport error, or a repository this
token cannot read AT ALL SKIPs that one reference by name and is counted in
`skipped=` on the arm's line — and the OK line now carries `resolved=N
skipped=M`, because `refs=gh-api:…` named the endpoint the arm meant to call
and not work done: with every per-reference call answering HTTP 403 the line
was byte-identical to a walk that resolved all seven. An authenticated caller
requires `skipped=0`. Arm (c) also keeps an EXPLICIT OWNER whole: round 3
extracted only the repository half, so `cli/Tidepool#59` deduplicated against
`InauguralSystems/Tidepool#59` and was certified by resolving a different
organisation's repository. Deduplication keys on the full owner/repo/number
triple, and an owner outside `KNOWN_OWNERS` is red by name rather than replaced
by the default. Arm (a) never
skips. Arm (c) also REFUSES a bare `#N` in a cell that also carries a qualified
`Repo#M`: M9's row read "Tidepool#43 and #59", the bare `#59` silently resolved
against EigenScript (a real, closed PR), and the row was green for a reference
it does not mean.

**`KNOWN_REPOS` is verified once per run, and a private repository is not
evidence.** Round 4's list named `EigenKB`, which **does not exist** — a 404 on
every token, including the organisation's most privileged one — and arm (c)
mapped a repository-level 404 to "this token cannot read the repository", a
statement about the run, so `EigenKB#1` in the roadmap SKIPPED BY NAME and the
gate printed `OK … skipped=1` (round-5 blind critic, Fable). A membership list
nothing verifies certifies whatever is typed into it. Arm (c) now makes ONE
call, `gh api orgs/<owner>/repos --paginate` (one page; how many rows come back
depends on the token — a repo-scoped `${{ github.token }}` sees the public
half only), and that
listing is the discriminator: name absent from a SUCCESSFUL listing → the
repository **does not exist**, red by name, `KNOWN_REPOS is stale`; name
present → `.private` decides which list it belongs on; listing fails or returns
empty → nothing is decidable and the verification **SKIPs by name** (the
reference walk still runs, exactly as before).

**The classifier fails CLOSED, and "public" is a positive fact the listing has
to state.** Round 6 asked `[ "$priv" = "true" ]` and called everything else
public — so a listing whose rows carry no `.private` at all (a projection, a
proxy, an API change, a `jq` that answered `null`) certified every entry as
public and printed `repos=verified:13` with not one explicit `false` in it.
Measured with a 13-row null fixture: the gate printed the byte-identical OK
line and `[99zd]` read 11/11 (round-6 blind critics, Astra and Fable,
converging). Now `false` is public, `true` is private, and **anything else is
UNKNOWN VISIBILITY** — red by name ("the organisation listing carries no
visibility for `<owner>/<repo>`; refusing to certify it public") with the run's
token set to `repos=skipped:visibility-unknown:N`, which the live pin refuses
at both callers. The token the shell classifies also carries its TYPE, because
`(.private|tostring)` maps the JSON **string** `"false"` onto the boolean; a
non-boolean arrives as `non-boolean:<type>` and cannot masquerade.

**"Absent" means absent-or-private when the view is public-only.** A
repo-scoped `${{ github.token }}` sees only the organisation's public half, so
on that lane a listing naming no private repository at all cannot tell a
DELETED repository from one that was turned private. The verdict is red either
way; the diagnosis changes — "absent from a public-only listing: deleted,
renamed, or now private — check with a token that can see private
repositories" — because sending a maintainer to look for a deleted repository
is the same false accusation in the other direction (round-6 blind critics,
ledger 4).

**A table row is not a separator because it contains `---`.** The row walk
skipped any row containing that substring anywhere, not only the header
separator, so a data row whose DONE clause read `never --- see the vetoes` was
never counted in `examined=` and never checked for cells, status or milestone
number (third critic, `/code-review 1226 medium`). One anchored regex,
`RC_SEP_RE`, now serves the separator COUNT, the section-placement check and
the walk — two spellings of one rule is how they disagree.

**Which of the listing outcomes above happened is on the OK line**, as
`repos=verified:N` or `repos=skipped:<why>` (round-5 blind
critic, Fable): until round 6 the verification left no trace there, so a run
whose listing 403'd, came back empty or was gutted printed a line
BYTE-IDENTICAL to a verified one and `[99zd]` passed 11/11 on a token-holding
lane. The contract admits both tokens; both callers require
`repos=verified:[1-9][0-9]*` once they have established for themselves that
GitHub is reachable. A `KNOWN_REPOS` entry the listing marks PRIVATE is told
apart from one that is ABSENT — "is now private (move it to PRIVATE_REPOS)"
versus "does not exist (KNOWN_REPOS is stale)" — and the selftest asserts each
plant's own diagnosis, not merely that arm (c) went red (round-5 blind critic,
Astra). A repo-scoped
`${{ github.token }}` sees only the organisation's public repositories, so for
a `PRIVATE_REPOS` entry "absent" and "private" are the same answer and both are
fine; an entry that shows up **public** is the stale direction and is red too.
`ROADMAP.md` is a PUBLIC document, so a citation its readers cannot open is not
evidence: `EigenOS`, `eigen-site`, `DeslanStudio` and `iLambdaAi` (measured
2026-09-21: `.private` is true on all four) moved out of `KNOWN_REPOS` into
`PRIVATE_REPOS`, which keeps them recognisable so that citing one is red for
its REAL reason ("private repository is not evidence in a public roadmap")
rather than red as an unrecognised name. Under round 4 those citations RESOLVED
on a maintainer's token and were counted as evidence, and would have been
`skipped=1` — and therefore red at the token-holding daily lane, for the wrong
reason — under `${{ github.token }}`. The selftest drives all of this through
an organisation-listing fixture, offline: a missing entry, a private entry, a
cited private repository, and the CONTROL that makes the discriminator load-
bearing — the same missing entry with the listing UNREADABLE is **green**, so
gutting the discriminator is red in one direction and silent in the other, and
the pair catches both. Round 7 added four more: a listing with no visibility
at all, a `.private` that is a string rather than a boolean, an entry absent
from a public-only view, and a data row whose cell contains `---`. The case
count is PUBLISHED by `--selftest`'s summary line and by `--contract`, and the
**two** callers — `[99zd]` in `tests/run_all_tests.sh` and the roadmap step in
`.github/workflows/issue-triage.yml` — each pin their own copy of it, so a
count that moves is a deliberate edit in three places rather than a silent
adoption.

The old file was a checkbox pile, most of it historical highlights under
`## Completed`, so every counter of "roadmap items" was counting the past.
ROADMAP.md's own header states both pre-PR counts beside the commands that
produce them, and `tools/docs_claims_check.sh` RUNS those commands
(`D_ROADMAP_HIST_CHECKBOXES` / `D_ROADMAP_HIST_COMPLETED`) rather than waiving
them — a waiver whose reason describes a derivation nobody executes is a
promise, not a measurement. On a checkout too shallow to reach the commit the
two claims defer by name into their own declared class. This page deliberately
does not retype either number.

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

All three tools carry a planted-fault `--selftest` with a pinned case count and
a `--contract`, and the suite runs the live pass, the contract and the selftest
of each as `[99zd]`.

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
