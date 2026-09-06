# Embed observer contract: validation (#1038 / #1028)

The first sections record round 1. The
[round-2 record](#round-2-raw-host-coverage) distinguishes state creation from
the separate embed-initialization pin; the
[round-3 record](#round-3-explicit-host-arming-across-an-isolated-eval-boundary)
corrects the explicit-host-arm recipe across an isolated eval boundary.

Baseline: `origin/main` at `cd99388163c3ff6478851de1f5be906f7626341a`.
The baseline runtime was built in this worktree before the runtime edits.
The regression is `tests/test_embed_observer.c`; its normal runner is
`bash tests/test_embed_observer.sh`, which selects the CLI's runtime variant.

## Native/assembled oracle

The direct arm never calls `compile_ast`, `eigs_eval_string` or
`eigs_obs_enable`. It feeds a descending numeric trajectory through the native
slot API, then assembles and executes assignments plus a named predicate.
The equivalent source trajectory returns `improving=1` in the baseline VM.

Using the branch's test source with a baseline runtime/header, compile with
`-DEIGS_OBS_BASELINE_ONLY` to omit calls to the new API. For example, in a
worktree built from the baseline revision:

```bash
make
objects=()
for obj in build/release/*.o; do
    case "$obj" in */main.o|*/test_*.o) ;; *) objects+=("$obj");; esac
done
gcc -Wall -Wextra -Werror=switch -Werror=comment \
    -Werror=misleading-indentation -DEIGS_OBS_BASELINE_ONLY -Isrc \
    tests/test_embed_observer.c "${objects[@]}" -lm -lpthread \
    -o build/release/test_embed_observer_main
build/release/test_embed_observer_main --direct
```

Measured baseline (exit 1):

```text
native improving=0
FAIL: native slot updates observe without compile_ast
assembled improving=0
FAIL: assembled writes and predicate match native improving=1
embed observer: 0 passed, 2 failed
```

Branch: `make embed-observer-test` then
`build/release/test_embed_observer --direct` (exit 0):

```text
native improving=1
PASS: native slot updates observe without compile_ast
assembled improving=1
PASS: assembled writes and predicate match native improving=1
embed observer: 2 passed, 0 failed
```

## Eval seam and planted fault

`bash tests/test_embed_observer.sh`: **28 passed, 0 failed**, exit 0. It checks
default cross-unit history, isolated units, sticky rejection, force-on recovery,
state independence, low-level module compilation, retained functions and opaque C callbacks. The harness
requires the exact assertion count, the real compiler's `unobserved` stats,
its post-execution gate witness, successful exit and no sanitizer diagnostics.

With no suite running, saved `src/eigs_embed.c`, removed only the `rt_error`
call in `eval_source`'s history-gap guard, then ran that same runner:

```text
FAIL: opt-in: cross-unit read raises instead of zero
FAIL: opt-in: repeated read cannot clear history gap
FAIL: disabling opt-in cannot repair lost history
FAIL: late callback: registration cannot hide missing history
embed observer: 24 passed, 4 failed
```

Exit 1. Restored the saved source (not a checkout from Git), rebuilt through the
same runner: **28 passed, 0 failed**, exit 0.

A separate C callback reproducer initially returned `callback improving=0
error=0` under the new opt-in despite creating its trajectory entirely within
the call. After callback registration pinned eval recording open, the exact
reproducer returned `callback improving=1 error=0`. The C regression preserves
that case, including enabling isolation *after* registering the callback.

A native host/module probe exposed a second seam: C recorded a descending
trajectory, called `load_file` for a read-free module, then recorded a rising
trajectory. Before embed initialization pinned recording, it printed:

```text
module error=0 gate=0
after rising: improving=1
```

Exit 1: the rising trajectory was answered from the stale descending window.
The control with an explicit startup `eigs_obs_enable()` returned 0 with
`gate=1` and `improving=0`. After the fix, the **same probe without that call**
returned 0 with `gate=1` and `improving=0`. The C test also directly compiles and
executes a read-free module before invoking native observation. Embed runtime
initialization pins recording so a module cannot classify its C caller; the
CLI's initial compile and the explicit eval opt-in retain their gating path.

## CLI verdict

```bash
EIGS_OBS_GATE_STATS=1 src/eigenscript -e 'x is 41
print of (x + 1)'
```

```text
obs-gate: unobserved <module>
42
```

## Benchmark fixture provenance

EigenMiniSat snapshot: `cca0e1482da91ad5b2b61b3cf775a04d5a5ca4de`, archived into
`build/observer-EigenMiniSat` inside this worktree. Its unmodified checkout has
no `eigs.json`; the current runtime's file-resolution contract rejects
`lib/dimacs.eigs` from `benchmarks/tseitin_ladder.eigs` (exit 1). This is a
fixture setup difference from the historical #915 measurement.

Added only `eigs.json` containing `{"name":"observer-gate-benchmark"}` to that
scratch copy, so its root-relative module names use the documented project-root
resolution. No benchmark/solver source changes. The small preflight then
completed with `status=UNSAT`. The timing comparison uses this same configured
snapshot for both arms.

Completed timing command:

```bash
EMS="$PWD/build/observer-EigenMiniSat" N=5 ROWS=4 COLS=4 \
    bash tools/observer_gate_measure.sh
```

```text
base  median: 287.78 s   (289.21 288.18 287.78 285.53 285.97)
gated median: 30.54 s   (30.54 30.32 31.03 30.35 30.56)
counters, identical across all 10 runs:
  DONE case=tseitin-torus-4x4-odd rows=4 cols=4 vars=32 clauses=128 status=UNSAT conflicts=9986 resolutions=33873 learnts=9985 learnt_lits=78856 peak_learnts=1595 max_level=19 decisions=15275 propagations=44166 restarts=11
speedup: 9.42x
RESULT: valid — same search, same binary, interleaved
```

Exit 0. This run measured **9.42x**, rather than the brief's historical 8.5x;
the current fixture and binary retain a substantial observer-elision benefit.
An earlier timing attempt was interrupted by the session's wall-clock limit
after four pairs. None of those partial-run timings enter these medians; the
reported run restarted all five pairs and completed every counter check.

## Runtime gates

Commands run sequentially in the worktree:

| Command | Measured result |
|---|---|
| `make && (cd tests && bash run_all_tests.sh)` | 4259/4259 passed, 0 failed; all child tests completed. |
| `make asan && (cd tests && ASAN_OPTIONS=detect_leaks=1 bash run_all_tests.sh)` | 4248/4248 passed, 0 failed; no leak reports; C contract 28/28. |
| `make tsan && bash tests/test_tsan.sh` | 14 passed, 0 failed: 13 race-free programs, including `test_obs_mt_race`, and the live seeded-race control. |
| `bash tools/observer_gate_diff.sh capture main`, `capture main2`, then `capture branch` and `compare main branch` | 521 captured, 5 denied; 497 byte-identical (399 informative, 98 silent), 24 excluded by baseline self-difference, 0 mismatches. |
| `bash tools/jit_diff.sh` | 230 programs against interpreter, 4 arms adjudicated by replay, 0 ledgered differences. |

Both full suites include the fail-soft classification, strict argument-guard
(`--no-baseline`), suite-label, observer-classification and warning-flag gates.
The warning audit checked **481 compile invocations across 29 targets and
7 scripts**, including the new C regression target. TSan's intentionally racy
control emitted **5 warnings** before its 120-second timeout; the 13 clean
programs completed without warnings.

After restoring release with `make`, its SHA-256 remained
`7260633c29791dd5bac01b2884b8203ffc601d2b2bc29a91c5718a3d9528384f`,
identical to the binary used for the final release suite and differentials.
The read-free CLI probe still printed `obs-gate: unobserved <module>` and `42`.

The replay oracle **returned OK but was not clean**: `bash tools/replay_diff.sh`
reported 230 programs, 12 documented boundaries, 0 nondeterministic cases and
0 ledgered differences, while printing a SIGSEGV for the replay arm of
`test_spawn_channel_exit.eigs`. A separate bounded reproducer confirmed the
crash on **unmodified main 20/20 and the branch 20/20**; all 40 recordings
succeeded and wrote tapes, and every replay printed the unsupported-concurrency
diagnostic before crashing. The boundary classifier then skips the crash.
Reported separately as [#1112](https://github.com/InauguralSystems/EigenScript/issues/1112).

```bash
EIGS_JIT_OFF=1 EIGS_TRACE=/tmp/spawn-exit.tape src/eigenscript tests/test_spawn_channel_exit.eigs
EIGS_JIT_OFF=1 EIGS_REPLAY=/tmp/spawn-exit.tape src/eigenscript tests/test_spawn_channel_exit.eigs
```

The record exits 0; replay exits 139. This pre-existing failure must not be
read as a clean replay result merely because the harness exits 0.

## Round 2: raw-host coverage

Starting tree: clean `fix-1038` at `7c7a11d`. Both critics found that the
round-1 test's `eigs_open` path always armed through `eigs_state_init_runtime`,
so it could not detect reverting the separate `eigs_state_new` default.
The shipped test now also has `--raw-host`: create and attach a raw state,
allocate an environment, record twelve descending updates, and interrogate
the resulting trajectory. It never initializes the runtime, compiles source
or explicitly arms recording. The original `eigs_open` checks remain.

`make embed-observer-test` and `bash tests/test_embed_observer.sh`:
**31 passed, 0 failed**, exit 0. Isolated witness:

```text
raw host: obs_needed=1 improving=1
PASS: raw host: state creation records without init_runtime
embed observer: 1 passed, 0 failed
```

Copied the worktree with `cp -a` to `/tmp/es1038-r2-plant`, changed only
`src/state.c`'s `st->obs_needed = 1;` to `0`, and ran plain `make` followed by
the same C runner. It exited 1 with **30 passed, 1 failed**. Its isolated
`build/release/test_embed_observer --raw-host` also exited 1:

```text
raw host: obs_needed=0 improving=0
FAIL: raw host: state creation records without init_runtime
embed observer: 0 passed, 1 failed
```

F2's clear already uses `obs_flag_store`, whose implementation is
`__atomic_store_n(..., __ATOMIC_RELEASE)`; preprocessing `src/compiler.c`
confirmed that exact expansion. No runtime store was changed. The CLI's first
compile precedes execution/spawn; normal embedding consumes the first-compile
permission at initialization; isolated eval boundaries require exclusive state
access. A raw host must likewise serialize its first compile against native
arming/execution. An exchange of `obs_needed` alone would not serialize the
surrounding check-then-clear decision. The source comment now names that limit,
and the C test covers a raw first compile followed by concurrent worker arming
and atomic flag reads. The TSan lane now runs the C contract with failures and
sanitizer reports fatal, in addition to its existing concurrency slice.

F3 documents that direct host predicates between isolated eval units bypass
the eval guard: recording must be arranged before the relevant assignments,
and late arming cannot recover missing history.

Round-2 gates, run sequentially (each full suite once):

| Command | Measured result |
|---|---|
| `make && (cd tests && bash run_all_tests.sh)` | 4259/4259 passed, 0 failed. |
| `make asan && (cd tests && ASAN_OPTIONS=detect_leaks=1 bash run_all_tests.sh)` | 4248/4248 passed, 0 failed; no leak reports; C contract 31/31. |
| `make tsan && bash tests/test_tsan.sh` | 15 passed, 0 failed: 13 clean programs, the C contract (31/31), and the seeded race (14 warnings before its 120-second timeout). |

Both full suites audited 481 compile invocations across 29 targets and seven
scripts. After restoring release, the CLI probe still printed
`obs-gate: unobserved <module>` and `42`; its SHA-256 remained
`7260633c29791dd5bac01b2884b8203ffc601d2b2bc29a91c5718a3d9528384f`.

Fresh differential baseline: copied the worktree with `cp -a` to
`/tmp/es1038-r2-main`, reversed `git diff origin/main -- src` with `patch -R`,
then ran `make clean` and plain `make` in that copy. All six changed runtime
files were compared byte-for-byte with `git show origin/main:<path>` before
using the binary. Source revision:
`cd99388163c3ff6478851de1f5be906f7626341a`; rebuilt binary SHA-256:
`305b8c73a74e5d6478d48f0c3c20f872e97b9aec41ad4f40f8c125a2a5f83be5`.
The canonical checkout's binary was not used.

Captured this fresh baseline twice (`main`, `main2`), then reapplied the runtime
patch and rebuilt the branch **in that same scratch directory**. Its binary
SHA-256 matched the validated worktree release binary above. Holding the
executable path constant matters: an initial comparison with the branch binary
in the original worktree reported seven differences, all executable-relative
import diagnostics (two shadow warnings and five missing-file diagnostics).
No output normalization or exclusion rule was changed to remove those
differences.

With `EIGS_GATE_DIFF_DIR="$PWD/build/observer-r2-captures"` and
`EIGS_GATE_DIFF_BIN=/tmp/es1038-r2-main/src/eigenscript`, ran
`bash tools/observer_gate_diff.sh capture main`, `capture main2`, then, after
the in-place branch rebuild, `capture branch_samepath` and
`compare main branch_samepath`. Each capture reported **521 programs, 5 denied**.
The comparison exited 0:

```text
provenance: base=305b8c73a74e(force=0) ref=305b8c73a74e(force=0) gated=7260633c2979(force=0)
corpus entries with captures: 520
nondeterministic under a FIXED build (excluded): 23
compared: 497 (informative: 401, silent: 96)
mismatches: 0
RESULT: PASS — 497 programs byte-identical
```

The attempt/entry count difference exposed an existing capture limitation:
`test_terminal.eigs` reads from the corpus loop's stdin, truncating the next
path to `ts/test_throw_unwind.eigs`. All three captures contain that invalid
path's error, while the actual `tests/test_throw_unwind.eigs` capture is absent
from all three and therefore skipped by comparison. The 497-program claim
does **not** include that test. This is recorded as a separate harness gap;
the observer differential tool was unchanged in this round.

The independent read-free probe, run after restoring release:

```bash
EIGS_OBS_GATE_STATS=1 src/eigenscript -e $'x is 41\nprint of (x + 1)'
```

It exited 0 with `obs-gate: unobserved <module>` and output `42`.

## Round 3: explicit host arming across an isolated eval boundary

Starting tree: clean `fix-1038` at `babd15f`. The round-2 direct-host recipe
was wrong: an isolated eval renewed compile permission after the host armed,
so its read-free verdict discarded the assignments that C would interrogate.
This round makes the recipe work rather than replacing it with an opt-out.

The public `eigs_obs_enable()` now sets a separate atomic host request and
arms the current unit through the existing recording helper. At the next eval
compilation boundary, an atomic exchange consumes that request and suppresses
permission to close that unit. Internal compiler/runtime calls use
`eigs_obs_enable_runtime()` without creating a future host request. Its
gap-before-needed release stores are unchanged, as is the compile scan's
verdict logic. A subsequent read-free unit can gate again. The new flag owns
no runtime objects and adds no tape record or per-assignment work.

The C regression's `--isolated-host` arm follows the actual host recipe:
`eigs_open`, isolation on, explicit arm twice (idempotence), read-free eval,
then a direct `observer_predicate_at` on `x`. No compiled predicate can rescue
the eval. The arm also executes another read-free unit and requires its gate
to close, proving the host request is consumed once.

Before changing runtime code, built the fixture with
`make embed-observer-test` against `babd15f`:

```text
isolated host: DIRECT improving=0 obs_needed=0 gap=0
FAIL: isolated host: explicit arming survives the eval boundary
embed observer: 3 passed, 1 failed
```

`build/release/test_embed_observer --isolated-host` exited 1, and the complete
`bash tests/test_embed_observer.sh` exited 1 with **34 passed, 1 failed**.
After the fix and a release rebuild:

```text
isolated host: DIRECT improving=1 obs_needed=1 gap=0
PASS: isolated host: explicit arming survives the eval boundary
embed observer: 4 passed, 0 failed
```

The isolated arm exited 0; the complete C runner reported **35 passed,
0 failed**. Existing raw-host and cross-unit history-gap arms remain enrolled.
The worker-arming test now reads the new atomic host-request flag concurrently
and checks it after joining the worker; the TSan lane runs this C fixture.

F5 is resolved by documenting the supported host serialization contract in
`EMBEDDING.md`: a raw host must serialize its first compilation against worker
arming/execution. Atomic flag stores do not make that multi-flag decision a
transaction. Opted-in eval boundaries already require exclusive state access.
F6 removes the stale numeric flag count from the atomic-access comment.

Round-3 gates, run sequentially (each full suite once):

| Command | Measured result |
|---|---|
| `make && (cd tests && bash run_all_tests.sh)` | 4259/4259 passed, 0 failed; every child completed, 0 nonzero exits. |
| `make asan && (cd tests && ASAN_OPTIONS=detect_leaks=1 bash run_all_tests.sh)` | 4248/4248 passed, 0 failed; every child completed, 0 nonzero exits; no ASan/UBSan/leak reports. |
| `make tsan && bash tests/test_tsan.sh` | 15 passed, 0 failed: 13 clean programs, the C contract (35/35), and the seeded race (16 warnings detected). |

Both full suites ran the C contract (35/35), audited **481 compile invocations
across 29 targets and seven scripts**, and recognized **89 scripts with six
shape waivers**. The ASan C preflight also passed 35/35 with leak detection on.

After restoring release with `make`, the read-free probe
`EIGS_OBS_GATE_STATS=1 src/eigenscript -e $'x is 41\nprint of (x + 1)'`
exited 0 with `obs-gate: unobserved <module>` and `42`. Release binary SHA-256:
`11310dc5efbab32e4a3d1a4b66168de50ed923173990613790709ea69ad7bf19`.

For the round-3 differential, copied the worktree with `cp -a` to
`/tmp/es1038-r3-oracle`, reversed `git diff origin/main -- src` with `patch -R`,
and verified all **nine** affected runtime files against
`git show origin/main:<path>`. Ran `make clean` and plain `make` in the copy.
Baseline source: `cd99388163c3ff6478851de1f5be906f7626341a`; fresh binary SHA-256:
`305b8c73a74e5d6478d48f0c3c20f872e97b9aec41ad4f40f8c125a2a5f83be5`.

Captured `main` and `main2` with that binary, then reapplied the runtime patch
and rebuilt the branch in the **same scratch directory**. All nine runtime
files matched the validated worktree, and the resulting binary matched its
release SHA-256 above. The capture manifest's `rev` identifies the calling
worktree (`babd15f`); the source comparison and binary SHA identify the actual
baseline executable. The canonical checkout was not built or used.

From the original worktree, with
`EIGS_GATE_DIFF_DIR="$PWD/build/observer-r3-captures"` and
`EIGS_GATE_DIFF_BIN=/tmp/es1038-r3-oracle/src/eigenscript`, ran
`bash tools/observer_gate_diff.sh capture main`, `capture main2`, then after
the branch rebuild, `capture branch` and `compare main branch`. Captures unset
`EIGS_OBS_FORCE`, `EIGS_OBS_GATE_STATS`, `EIGS_TRACE`, `EIGS_REPLAY` and
`EIGS_JIT_OFF`; both baseline captures reported **521 programs, 5 denied**.

The branch capture also reported **521 programs, 5 denied**. Comparison exited
0 with the following totals:

```text
provenance: base=305b8c73a74e(force=0) ref=305b8c73a74e(force=0) gated=11310dc5efba(force=0)
corpus entries with captures: 520
nondeterministic under a FIXED build (excluded): 23
compared: 497 (informative: 401, silent: 96)
mismatches: 0
RESULT: PASS — 497 programs byte-identical
```

The round-2 capture limitation remains: the terminal fixture consumes corpus
stdin, leaving `ts/test_throw_unwind.eigs` instead of the real next path in
all three captures. `tests/test_throw_unwind.eigs` is therefore outside the
497-program comparison. No differential-tool normalization, exclusion rule
or coverage floor was changed. No new measurement contradicted the round-3
brief; the reported F4 silent-wrong recipe was reproduced and repaired.
