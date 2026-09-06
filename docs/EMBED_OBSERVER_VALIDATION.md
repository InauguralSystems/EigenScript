# Embed observer contract: validation (#1038 / #1028)

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
