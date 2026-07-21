# CLAUDE.md — EigenScript working guide

EigenScript is a C-implemented language runtime: lexer → parser →
bytecode compiler → stack VM (computed-goto dispatch) with a
copy-and-patch x86-64 JIT, an observer system (entropy/dH tracking on
every assignment), and a reversibility layer (temporal interrogatives,
trace tape, deterministic replay).

## When you hit a gap, file an issue — proactively, without being asked

Working here you WILL hit a missing feature, a rough edge, or a bug. The
standing rule for every agent and contributor: **surface the gap, don't work
around it silently.** Open a GitHub issue with a minimal repro
(`gh issue create`), or fold the fix into your PR and reference it. A silent
workaround discards the one signal this project runs on — real use finding real
gaps. This is the forcing-function model (see Ecosystem) applied to your own
session: a gap you route upstream is a contribution; a gap you paper over is
lost data. Do this without being told, the way you'd run the tests without being
told.

## Before merging your own PR, clear ready contributor PRs first

External contributors work from **forks we cannot push to** — a fork branch is
theirs. If our merge makes their PR stale, the only remedies are asking them to
rebase (friction, delay) or the fetch-rebase-reland dance (see #657). Our OWN PRs
we rebase for free. So before merging one of ours: `gh pr list` and land any
**ready** contributor PR (green + reviewed, not authored by us) first, then rebase
ours onto the new main. Rebasing our own costs nothing; asking them does. (Only
*ready* PRs — never merge an unready contributor PR just to dodge a rebase.)

## Build & test

```
make            # release build -> src/eigenscript (HTTP/MODEL/DB off)
make test       # build + full suite (tests/run_all_tests.sh)
make asan       # ASan+UBSan build (same binary path!)
make http       # http+model variant — run tests/test_http_server.sh
make jit-smoke  # standalone emitter tests (jit_smoke.c stubs all helpers)
make freestanding-check  # 2-stage symbol gate for the EigenOS profile (docs/FREESTANDING.md)
make freestanding-libc-diff  # mini-libc/libm vs glibc oracle (src/freestanding/)
make poison     # 0xAA uninit-read hunter build; run the suite with MALLOC_PERTURB_=170
bash tools/embed_stack_soak.sh  # embed REPL soak inside a 64 KiB stack rlimit (CI gate)
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
  was all spawn/channel programs; three fixes cleared it: (1) channel + thread
  *handle*-table resources (Channel structs + ThreadHandles live in the process
  handle table keyed by id, not on a GC'd Value) are reclaimed deterministically
  by `handle_table_drain` once the program finishes; (2) the worker's return
  value was over-incref'd in `thread_entry` (removed); (3) **threaded cycle-GC** —
  the collector's candidate registry moved per-thread→per-state (lock-guarded,
  `gc_lock`), so env↔closure cycles created on any thread during the MT window
  stay collection candidates and the exit collector sweeps them once workers are
  joined (`handle_table_drain` clears `multithreaded`). So MT-created cycles no
  longer leak — `test_concurrent` is clean, and section [101] (`test_spawn_gc`,
  worker-created cycles) is leak-gated. (#297 then made parallel shared-chunk
  execution TSan-clean: the multithreaded flag is written once on the 0→1
  transition, and the JIT counters / OSR / inline-cache writes / trace-line are
  gated off under MT, name hashes precomputed at compile time. ThreadSanitizer
  here needs `setarch -R` to disable ASLR.)
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
- **No big by-value arrays/structs in recursive functions.** The C stack is
  a resource axis no hosted gate bounds (8 MiB + guard page hides it); the
  `Compiler`'s inline `Local[512]` cost ~12.7 KiB of stack per AST level for
  23 versions until EigenOS's 64 KiB boot stack exposed it as a
  layout-sensitive heisenbug (PR #361). Audit with `gcc -fstack-usage`
  (≥ ~2 KiB in a recursive path is suspect); `tools/embed_stack_soak.sh`
  (CI) is the regression gate and also the only multi-eval-per-EigsState
  coverage in the repo.
- **`tests/test_temporal.eigs` is line-number-sensitive** — its `at`
  queries hardcode line numbers. Append only before the final if/else, and
  re-verify the `grep -n` markers in the file.
- **Brackets after `of` are an argument list; parentheses are one
  argument** (#405, closed #153): a bare literal list is an arg list at
  EVERY count — `f of []` zero args, `f of [x]` one arg (the element,
  not the list), `f of [a, b]` two. To pass a literal list whole,
  parenthesise (#355): `f of ([x])`. Lint W017 flags the 1-element bare
  form (pre-#405 it meant the opposite). (More `.eigs`-writing gotchas:
  the `write-eigenscript` skill.)
- The Makefile `asan` target compiles with `EIGENSCRIPT_EXT_HTTP=0`; if you
  touch `ext_http.c`, compile-check with `make http`. Same for `ext_gfx.c`
  — in **no** default build; compile-check with `make gfx`. All variants
  land on `src/eigenscript`, so never rebuild one while a suite run against
  another is in flight.
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

- **Latest release: v0.32.0** (2026-07-16) — the desktop-shell release:
  lib/ui's gap series (#561–#577, #594), surfaced by DeslanStudio's port —
  the toolkit's first real consumer — and closed. The toolkit now owns what
  the shell hand-rolled: `handle_key` (#563, keyboard through `dispatch`
  instead of trapped inside `app_loop`, priority pinned in one place),
  `request_quit` (#564, ending the loop from a callback instead of `exit of
  N` skipping `gfx_close`), clickable combobox dropdown items (#577 —
  hit-test before closing, select by the click's own y, and exempt popups
  from double-click detection), self-measuring `label` w/h + `auto_size`
  (#561), `grid.owns_cells` + a configurable row-label gutter (#572),
  piano-key release wherever the pointer lands (#570), hover feedback on
  checkbox/toggle (#594), and **`menu_bar`** (#565 — owning its popup's
  z-order via the `_render_popups` overlay pass + `_find_open_popup_at`,
  since rendering above the tree is only half of z-order). Three of the ten
  filed issues had already been fixed and were closed with probe output, not
  re-fixed. (v0.31.0, 2026-07-14: DAW audio-I/O + live-synthesis — bulk
  audio-I/O kernels #602/#603, the live audio-streaming primitive
  `audio_stream_*` #612, `waveform_view` selection markers #610/#611.
  v0.30.0, 2026-07-13: debugging-and-distribution + first-consumer —
  `--step` tape stepper #418, tape format v2 #539, error carets/LSP ranges
  #407, `--bundle` #413, entropy-walk cycle detection #571, gfx audio
  capture #579 + buffer playback #578, the lib/ui input trio #567–#569.)
  Unreleased
  work on `main`: see CHANGELOG.md `[Unreleased]`. Full version history:
  **CHANGELOG.md** (don't re-narrate it here — tools/doc_drift_check.sh
  now FAILS the suite when this line falls behind the latest tag). Roadmap:
  **ROADMAP.md**.
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
  **awesome-eigenscript** (curated index — a list, not a registry).

## Releasing

Push a `v*` tag **or** dispatch the Release workflow (Actions → Release → Run
workflow), which creates the tag and builds in the same run. This
environment's git proxy **cannot push tags**, and GITHUB_TOKEN-pushed tags
don't retrigger workflows — so use the dispatch path. **The cut PR must update
this file's "Latest release" line to the new version**: doc-drift rule 2
compares it to the latest tag, and the release build runs *after* the tag is
created — a stale line fails the release's own suite (bit the v0.27.0 cut).
Homebrew tap: github.com/InauguralSystems/homebrew-eigenscript (tracks the
latest release).
