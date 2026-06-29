# CLAUDE.md — EigenScript working guide

EigenScript is a C-implemented language runtime: lexer → parser →
bytecode compiler → stack VM (computed-goto dispatch) with a
copy-and-patch x86-64 JIT, an observer system (entropy/dH tracking on
every assignment), and a reversibility layer (temporal interrogatives,
trace tape, deterministic replay).

## Build & test

```
make            # release build -> src/eigenscript (HTTP/MODEL/DB off)
make test       # build + full suite (tests/run_all_tests.sh)
make asan       # ASan+UBSan build (same binary path!)
make http       # http+model variant — run tests/test_http_server.sh
make jit-smoke  # standalone emitter tests (jit_smoke.c stubs all helpers)
```

- The suite must pass **both** release and ASan with leaks on:
  `make asan && cd tests && ASAN_OPTIONS=detect_leaks=1 bash run_all_tests.sh`
  (CI enforces `detect_leaks=1`).
- **Leak tally is the gate.** The env↔fn closure cycle is reclaimed by the
  cycle collector (docs/CLOSURE_CYCLE_GC.md); section **[87]**
  (`test_closure_cycles.eigs`) is gated **strictly** leak-clean — a
  LeakSanitizer exit there is a collector regression. The runner's `rc_ok`
  tolerates LeakSanitizer exits elsewhere and tallies them ("NOTE: N test
  program(s)…"): **currently 0** (was 4). **A jump in the tally means a new
  leak.** Any other nonzero exit — crash, assert, UBSan — fails. The old floor-4
  was all spawn/channel programs; two fixes cleared it: (1) channel + thread
  *handle*-table resources (Channel structs + ThreadHandles live in the process
  handle table keyed by id, not on a GC'd Value) are now reclaimed
  deterministically by `handle_table_drain` once the program finishes; (2) the
  worker's return value was over-incref'd in `thread_entry` (a second ref with
  no owner — `vm_execute` already returns an owned ref), now removed. **Caveat:**
  `test_concurrent` ([55]) still leaks ~21 KB of main-thread env↔closure cycles
  created *after* the first `spawn` — `env_mark_captured` skips GC registration
  while multithreaded (to avoid a cross-thread register/unregister hazard), so
  they're never collection candidates. It's NOT in the tally because the [55]
  block is marker-only (no `rc_ok`) — a gating gap. Reclaiming it needs a
  thread-safe GC registry (threading hardening); tightening [55] to `rc_ok`
  should wait until then or it red-lines CI.
- `make asan` overwrites `src/eigenscript` — rebuild with `make` before timing.
- Benchmarks: `tests/bench_perf.eigs` (micro), `tests/bench_dmg_shape.eigs`
  (dispatch-table interpreter shape, the DMG/cpu_instrs stand-in),
  `tests/bench_idxset.eigs` (fn-local buffer/list write loop — one JIT thunk,
  zero bailouts).

## Hard-won rules (violations have bitten before)

- **Refcounts**: `env_set_local`, `list_append`, `dict_set` incref
  internally. Storing a freshly made value? Use the adopting variants
  `env_set_local_owned` / `list_append_owned` / `dict_set_owned`, or
  decref after storing. The bare `store(make_x(...))` idiom is a leak.
- **Chunks are refcounted** (creator + per-VAL_FN + per-call-frame).
  `chunk_free` = drop creator ref. JIT return thunks write
  `chunk->jit_advance` *after* `jit_helper_return` — the popped frame's
  chunk ref is dropped in vm_run's `-1` sentinel handlers, never in the
  helpers.
- **Env refcounts are honest and the cycle collector depends on it**:
  every owner of an `Env` — frame/creator, closure (`make_fn`), child env
  (`parent` is an owned edge), parked `chunk->env_cache` — holds a counted
  ref via `env_incref`/`env_decref`. Never stash a bare `Env*` that
  outlives its creator. The collector's `GC_FOR_EACH_CHILD` walker and
  `gc_clear_node` (eigenscript.c) must move in lockstep with the ownership
  model: a new owning edge out of Value/Env/Chunk goes into both, and only
  *counted* edges may be traversed (an uncounted edge trips the accounting
  abort and collection silently stops working). Conservative direction:
  missing an edge leaks; inventing one frees live memory.
- **Trace gating**: `g_trace_hist` (assignment history) and
  `g_trace_obs_hist` (observer snapshots) are compiler-set flags —
  recording is off unless the program contains a temporal query
  (`prev of`, `at`, `state_at`) or `EIGS_TRACE` is set. Don't add always-on
  per-assign work; it cost ~1/3 of dispatch-heavy runtime once before.
- **Suite sections gate on exit codes too** (`rc_ok` in run_all_tests.sh):
  marker-grep alone used to let a crash *after* correct output pass. New
  .eigs sections should use `check_eigs_suite` (rc + marker). The one
  tolerated nonzero exit is a LeakSanitizer report (see the leak tally
  above; section [87] deliberately opts out of that tolerance).
- **`tests/test_temporal.eigs` is line-number-sensitive** — its `at`
  queries hardcode line numbers. Append only before the final if/else, and
  re-verify the `grep -n` markers in the file.
- **`f of [x]` does not spread** — the compiler spreads literal list args
  only at `count > 1`, so a 1-element list binds the *whole list* to the
  first param. For 1-arg calls to multi-param (incl. defaulted) functions
  use `f of (x)`. This breaks the obvious recursive form `fib of [n - 1]`
  the moment a defaulted param is added (issue #153). (More `.eigs`-writing
  gotchas: the `write-eigenscript` skill.)
- The Makefile `asan` target compiles with `EIGENSCRIPT_EXT_HTTP=0`; if you
  touch `ext_http.c`, compile-check with `make http`. Same for `ext_gfx.c`
  — in **no** default build; compile-check with `make gfx`. All variants
  land on `src/eigenscript`, so never rebuild one while a suite run against
  another is in flight.
- `make test` must run with stdin available or redirected from /dev/null —
  `test_terminal.eigs` blocks forever reading a pipe that never EOFs.
- **A semantics change must update `docs/SPEC.md` + `docs/COMPARISON.md` in
  the same PR** — `tests/test_doc_examples.py` runs their example/output
  pairs byte-for-byte (suite [89]/[90]) and CI fails otherwise.

## Task-specific procedures (skills — invoked on demand, not always loaded)

- **Touching the JIT** (`src/jit.c`/`jit.h`, OSR/thunks, JIT inline fast
  paths)? → the **`eigenscript-jit`** skill (emitter invariants, `last_imm`
  peephole, advance sentinels, the inline-vs-measure trap, platform split).
- **Adding an opcode / AST node / CallFrame field / JIT helper / nondet
  builtin**? → the **`eigenscript-extend-vm`** skill (the "update all N
  sites" checklists — silent capture/replay/ABI bugs).
- **Changing the AOT compiler** (separate `ouroboros` repo)? → the
  **`aot-differential`** skill (VM as byte-exact oracle).
- **Writing `.eigs` code**? → the **`write-eigenscript`** skill.

## Current state & where the detail lives

- **Latest release: v0.21.2** (2026-06-29). Unreleased work on `main`: see
  CHANGELOG.md `[Unreleased]`. Full version history: **CHANGELOG.md**
  (don't re-narrate it here). Roadmap / open items: **ROADMAP.md**.
- **Design phase:** the VM tier is the deliberate correctness-first phase —
  its malleability keeps semantics cheap to change; the native path is the
  **AOT compiler in the sibling `ouroboros` repo** (the VM is its byte-exact
  oracle), not the JIT. Don't grind the JIT toward native perf; route
  perf-critical code through AOT.
- Embedding / multi-state (multiple `EigsState` per process): docs/EMBEDDING.md.
  Observer predicates lattice: docs/PREDICATES.md.

## Ecosystem (sibling repos under `InauguralSystems/`)

This runtime is the center of a portfolio; each consumer project stresses a
different axis and surfaces gaps as upstream PRs (the "forcing-function"
model — don't work around a gap, surface it).

- **ouroboros** — the **self-hosting compiler** (EigenScript→bytecode→C VM,
  written in EigenScript) **and the AOT native compiler** (`aot/`,
  transpile-to-C; the VM is its byte-exact oracle). This — not the JIT — is
  the native-perf path. Changing it → the **`aot-differential`** skill.
  (No CLAUDE.md of its own yet.)
- **Consumer / forcing-function projects** (validate the language, drive
  primitives):
  - **iLambdaAi** — research system whose ternary transformer *generates*
    EigenScript, validated against the runtime's own parser/compiler (the
    no-oracle research project)
  - **Tidepool** — Spore-inspired cell-stage evolution game (AI/physics/gameplay)
  - **dynamics** — observer-rich dynamical-systems lab
  - **liferaft** — deterministic simulation tester (DST) for Raft (durable
    determinism); **tidelog** — serialization format + crash-recoverable store
  - **DMG** — Game Boy emulator; its `cpu_instrs` shape is the perf stand-in
  - **EigenMiniSat** (SAT solver + benchmark), **EigenRegex** (Pike-VM regex),
    **EigenGauntlet** (stress-app suite for constrained hardware)
- **Infra**: **eigen-site** (inauguralsystems.com landing + the self-owned HTTP
  attack target), **homebrew-eigenscript** (tap), **eigs-package-template**,
  **awesome-eigenscript** (registry).

## Releasing

Push a `v*` tag **or** dispatch the Release workflow (Actions → Release → Run
workflow), which creates the tag and builds in the same run. This
environment's git proxy **cannot push tags**, and GITHUB_TOKEN-pushed tags
don't retrigger workflows — so use the dispatch path. Homebrew tap:
github.com/InauguralSystems/homebrew-eigenscript (tracks the latest release).
