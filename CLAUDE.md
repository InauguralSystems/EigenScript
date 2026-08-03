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
make            # release build -> build/release/, src/eigenscript hard-links to it (HTTP/MODEL/DB off)
make test       # build + full suite (tests/run_all_tests.sh)
make asan       # ASan+UBSan build — extensions OFF
make asan-http  # ASan+UBSan *with* ext_http+model (CI gate; leaks still need RSS, see #731)
make http       # http+model variant — run tests/test_http_server.sh
make zlib       # DEFLATE codecs (inflate/deflate builtins) via system zlib (-lz)
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
- Variants build into per-variant `build/<variant>/` objdirs (#740) and
  coexist; `src/eigenscript` is a hard link to the last `make` target
  (hard, not symbolic — `/proc/self/exe`-relative stdlib resolution must
  keep seeing `src/`), so switching variants is an instant relink (`make`
  after `make asan` costs ~0.2s, not a rebuild). Don't run any `make`
  variant target while a suite is in flight — it re-points the alias
  under the suite (the #681 fingerprint guard catches it at the next
  section seam).
- Benchmarks: `tests/bench_perf.eigs` (micro), `tests/bench_dmg_shape.eigs`
  (dispatch-table interpreter shape, the DMG/cpu_instrs stand-in),
  `tests/bench_idxset.eigs` (fn-local buffer/list write loop — one JIT thunk,
  zero bailouts).

## Hard-won rules (violations have bitten before)

Two sets load on demand instead of every session — same rules, scoped to
where they bite:

- **Editing `src/*.c`/`*.h`?** → `.claude/rules/c-runtime-memory.md`
  (refcount/adopting variants, chunk + Env ownership and the cycle
  collector's lockstep requirement, trace gating, the C-stack rule, the
  ext_http/ext_gfx compile-check split).
- **Editing `tests/`?** → `.claude/rules/test-suite.md` (`rc_ok` exit-code
  gating and `check_eigs_suite`, `test_temporal.eigs`'s line-number
  sensitivity, the SPEC/COMPARISON byte-for-byte rule, the benchmarks).

Always-on:

- **Brackets after `of` are an argument list; parentheses are one
  argument** (#405, closed #153): a bare literal list is an arg list at
  EVERY count — `f of []` zero args, `f of [x]` one arg (the element,
  not the list), `f of [a, b]` two. To pass a literal list whole,
  parenthesise (#355): `f of ([x])`. Lint W017 flags the 1-element bare
  form (pre-#405 it meant the opposite). **Arity-1 carve-out (#733)**:
  that rule describes the call site, not the binding — a 1-parameter
  callee re-collects a 2+-element arg list WHOLE (`one of [5, 6]` binds
  `a = [5, 6]`, not `a = 5`; this is what keeps `len of [1, 2]`
  working). Over-arity on 2+-param callees is silently dropped — W022
  flags it for same-file callees. (More `.eigs`-writing gotchas:
  the `write-eigenscript` skill.)
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
- **Writing `.eigs` code**? → the **`write-eigenscript`** skill, and
  **`docs/llms.txt`** — the whole language in one 190-line file (call
  syntax, scope, observer, validation ladder); an agent primed with it
  has written correct programs from it alone (#734). Resolve "does
  function X exist" with `eigenscript --api` (or `--api --json`) — the
  full builtin/extension/lib surface index in one call.
- **Cutting a release** (tag/dispatch path, the doc-drift "Latest release"
  gate, the tap)? → the **`release`** skill.

## Current state & where the detail lives

- **Latest release: v0.35.0** (2026-08-02). Unreleased work on `main`: see
  CHANGELOG.md `[Unreleased]`. Full version history: **CHANGELOG.md** (don't
  re-narrate it here — tools/doc_drift_check.sh FAILS the suite when this line
  falls behind the latest tag). Roadmap: **ROADMAP.md**.
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
