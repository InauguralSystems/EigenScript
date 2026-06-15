# Roadmap

Current version: **0.12.0**

Recently shipped (0.12.0): JIT Stage 5 inline matrix (a–i) — buffer
INDEX_SET, EnvIC name get/set, 2-way dict-dot cache, tracked-num
arith/compare operands, native VAL_FN calls inside thunks, per-loop
OSR slots, DOT_SET in-place write, per-chunk call-env recycling — plus
temporal-trace compile gate (recording off unless the program uses
`prev of`/`at`/`state_at`). `bench_dmg_shape` 239 → ~118 ms (2.0×); JIT
now beats `EIGS_JIT_OFF` by ~45% on it.

## Next (0.13.0)

### Performance carryover

- [ ] **NaN-boxing for container storage** — stack and env slots are
      already EigsSlot/NaN-boxed; list items and dict values are still
      `Value**`. Post-5h, the DMG-shaped `make_num` churn is gone
      (writes mutate in place); this now mainly buys allocation-free
      list/dict construction and reads for non-num or shared values.
      Big surface (every `data.list.items` / `data.dict.vals` touch
      site).
- [ ] **Extend GET_LOCAL/SET_LOCAL to all local variables**
      (closure-safe). Currently restricted; broadening unlocks JIT
      inline ICs on every local, not just function params.
- [ ] **Per-call env churn** — `env_new` / `env_free` per call is the
      likely top DMG cost post-5i for non-recyclable callsites.
      Re-profile before picking; the profile shape moved every stage
      this cycle.

### Language features

- [x] Destructuring assignment (`[a, b] is [1, 2]`) — shipped 0.13.0
- [x] Streaming subprocess I/O (stdin pipe, unbuffered stdout) —
      shipped 0.13.0 (`proc_spawn` / `proc_write` / `proc_read_line` /
      `proc_read` / `proc_close` / `proc_wait`)
- [x] Negative indexing (`a[-1]`) — shipped 0.13.0
- [x] Slicing (`a[start:end]`, lists/strings/buffers, half-open,
      negatives, strict bounds, independent copy) — shipped 0.13.0
- [x] Default parameter values — shipped 0.13.0
- [x] Non-blocking channel recv (`recv_timeout of [ch, ms]`, plus
      suite coverage for the pre-existing `try_recv`) — shipped
      0.13.0; fixes Tidepool GAP-005
- [x] `spawn` with multiple args (`spawn of [fn, arg1, arg2, ...]`,
      positional, missing params → null, extras ignored, args shared
      by reference) — shipped 0.13.0; fixes Tidepool GAP-006
- [x] `audio_play_loop of [samples, loops]` finite-count loop
      playback — shipped 0.13.0; fixes Tidepool GAP-002 finite form
      (infinite-loop variant deferred — needs a background refill
      mechanism)

### Downstream gaps feeding back

Filed by stress-test repos; promote into a numbered EigenScript item
when picked up:

- **Tidepool** (`InauguralSystems/Tidepool/GAPS.md`):
  GAP-001/002/003 audio (sweep, loop, per-channel volume),
  GAP-003 per-channel volume (needs multi-channel mixer),
  GAP-004 inner-loop function-call cost (partial mitigation via
  v0.12.0 hoist sweep).
  (GAP-001 audio_sweep was already shipped; GAP-002 finite-count
  audio_play_loop shipped 0.13.0; GAP-005 non-blocking channel
  recv and GAP-006 spawn-with-args both shipped 0.13.0. GAP-002
  infinite loop variant still open.)
- **EigenMiniSat** (`InauguralSystems/EigenMiniSat/GAPS.md`):
  open watchlist around CDCL hot-path inlining patterns.

### Ecosystem

- [ ] Package manager / module registry
- [ ] More STEM modules (graph theory, regression, numerical PDEs)
- [ ] WASM compilation target
- [ ] Foreign function interface for calling arbitrary C libraries
      from script (libffi/libdl style — the *script → host* direction).
      The *host → script* direction (C host embeds the runtime + can
      register host functions callable from script) is live as of the
      Phase 10 embedding API; see [docs/EMBEDDING.md](docs/EMBEDDING.md).
- [ ] Crypto / HTTPS in-process (SHA hashes shipped 0.9.2; no AEAD, no TLS)
- [ ] Raw TCP/UDP sockets
- [ ] Additional DB drivers (SQLite, MySQL, NoSQL)
- [ ] bigint / decimal numeric types

### Long-term

- [ ] Self-hosting compiler (EigenScript written in EigenScript)
- [ ] GitHub Linguist submission (requires 2K+ .eigs files across repos)
- [ ] Public release

## Completed

### Unreleased — multi-state refactor + embedding API

- [x] **Multi-state refactor (Phases 1–9).** Every `__thread` global in
      the runtime now lives on `EigsState` (per-interpreter: global env,
      JIT cache, module cache, observer thresholds, handle table,
      multithread flag, JIT tuning thresholds) or `EigsThread`
      (per-OS-thread: arena, error state, VM, freelists, intern table,
      recursion-depth guards, cycle-collector registry). Hot fields keep
      single-indirection cost via `eigs_current->field` bridge macros, so
      the common single-state path is unchanged. Two `EigsState`
      instances can run concurrently in the same process with no shared
      state.
- [x] **Embedding API (Phase 10).** Public C surface in
      `src/eigs_embed.h`: opaque `EigsState` / `EigsThread` / `EigsValue`
      handles, lifecycle (`eigs_open` / `eigs_close` or finer-grained
      `eigs_state_new` / `eigs_thread_attach` / `eigs_state_init_runtime`),
      REPL-style source eval (`eigs_eval_string` / `eigs_eval_file`),
      error retrieval, global env read/write, ref-counted value
      constructors/accessors, and `eigs_register_function` for exposing
      host C functions to script. Contract test in `src/embed_smoke.c`
      (`make embed-smoke`). Reference: [docs/EMBEDDING.md](docs/EMBEDDING.md).

### 0.12.0 (2026-06-10)

- [x] **JIT Stage 5 — inline the hot fast paths.** Buffer-INDEX_SET
      and GET_NAME/SET name EnvIC fast paths emit as native templates
      with helper fallback on guard failure, plus a
      (env, binding_version, slot) write cache for the per-iteration
      `__loop_iterations__` update. bench_dmg_shape 239→218 ms,
      bench_idxset 29.7→24.6 ms; isolation probes 2.8–3.4×. Spec in
      `docs/JIT_STAGE5_INLINE_IC.md`.
- [x] **JIT Stage 5d — inline dict-dot fast paths.** LOCAL_DOT_GET/SET
      cache-hit paths emit inline (baked hash, interned-key pointer
      equality, in-place num mutate); helper fallback repopulates the
      dict cache. Isolated dict-RMW loop −31% (65→45 ms).
- [x] **JIT Stage 5e — tracked-num operands in arith/compare
      templates.** ADD/SUB/MUL/DIV/MOD and all six comparisons accept
      heap/tracked VAL_NUM operands (refcount ≥ 2; rc==1 routes to
      interpreter so NUM_REUSE keeps in-place semantics). JIT
      SET_LOCAL template gained the interpreter's exact in-place
      branch (the swap path would free a Value `g_last_observer` can
      still point at). Poisoned-counter loop −26% (141→105 ms);
      bench_idxset −10% (24.6→22.2 ms).
- [x] **JIT Stage 5f/5g — native VAL_FN calls + per-loop OSR slots.**
      Chunks carry one OSR slot per hot loop header (`jit_osr[4]`) so
      a setup loop can't pin the slot away from the main loop;
      `jit_helper_call` pushes the callee frame and invokes a compiled
      callee's thunk directly, with `-2` deep-bail sentinel. Plus
      OP_DOT_SET coverage. bench_dmg_shape 212→156 ms (−27%); JIT now
      ~33% faster than EIGS_JIT_OFF on it (previously near parity).
- [x] **Stage 5h — DOT_SET immediate fast path + 2-way dict cache.**
      DOT_SET mutates exclusive untracked num fields in place; the
      dict field cache is 2-way set-associative (the DMG "pc"/"cycles"
      pair collided in the direct map). dmg 156→118 ms; interpreter
      (EIGS_JIT_OFF) 230→213 ms.
- [x] **Stage 5i — per-chunk call-env recycling.** A returned call env
      parks on its chunk (values nulled; param names/hash/version
      kept) and the next call rebinds params in place — EnvICs stay
      valid across calls. Guarded: single-threaded, non-captured,
      fully-bound params, layout-exact count. env_new on
      bench_dmg_shape: 500k → 9 per run; trivial-call probe −26%
      (147→109 ms), recursive fib −17%.
- [x] **Temporal-trace compile gate.** `g_trace_hist` /
      `g_trace_obs_hist` set only when the program uses a temporal
      query or `EIGS_TRACE` is set — no per-assign cost otherwise.

### 0.11.5 → 0.11.8

- [x] Cross-platform CI + sanitizer matrix
- [x] HTTP server hardening (threaded accept, protocol hygiene)
- [x] Execution trace tape + deterministic replay
      (`EIGS_TRACE` / `EIGS_REPLAY`)
- [x] Temporal interrogatives (`prev of`, `at`, `state_at` +
      line-floor index)
- [x] Debugger step-back
- [x] Leak-clean suite under ASan (enforced in CI)
- [x] Refcounted bytecode chunks

### 0.11.4 (2026-05-23)

- [x] Dict-key interning + pointer-equality short-circuit in dict inline cache
- [x] PGO build target (`make pgo`)
- [x] Builtin ref-protocol fix — direct-borrow scan replaces unconditional
      compensating incref at CALL/JIT-helper/OP_DISPATCH sites; stops the
      fresh-builtin-return leak (range, make_str, keys, …)

### 0.11.0 → 0.11.2

- [x] Eliminate dispatch builtin re-entry (OP_DISPATCH inlines without re-entry)
- [x] In-place numeric mutation for refcount-1 values (NUM_REUSE)
- [x] Dict field inline caching (128-entry direct-mapped, 99.99% hit rate)
- [x] Stack-top arithmetic (ARITH_FAST) + inlined JUMP_IF/POP
- [x] Superinstructions: LOCAL_DOT_GET/SET, LOCAL_IDX_GET, LOCAL_IDX_DOT_GET/SET
- [x] Bytecode bring-up complete — eval.c deleted, VM is sole engine
- [x] Hit DMG 0.5+ MHz target (1.094 MHz at 0.11.4)

### 0.10.0 (2026-05-21)

- [x] Bytecode VM — replaced AST tree-walker with compiled bytecode + computed-goto dispatch
- [x] Non-recursive function calls — no C stack recursion, 4096 frame depth
- [x] Stack-local optimization — GET_LOCAL/SET_LOCAL for function params
- [x] Observer stall detection in VM loops (OP_LOOP_STALL_CHECK)
- [x] list_truncate, list_remove_at, sort_by builtins

### 0.9.3

- [x] Computational geometry library — 60+ functions, convex hull, transforms
- [x] Lab data collection framework
- [x] 49 stdlib modules, 14 STEM
- [x] 15 STEM simulation examples

### 0.9.2

- [x] 12 STEM standard library modules
- [x] SDL2 audio extension
- [x] Code formatter and linter
- [x] Tidepool game near-parity

### 0.9.1

- [x] Language server protocol (LSP) — eigenlsp, VS Code extension
- [x] Hashing builtins — SHA-256, MD5, HMAC-SHA256

### 0.9.0

- [x] UI toolkit — 44 widgets, 3 themes, flex layout, animation
- [x] Real concurrency — spawn/thread_join/channels
- [x] EigenStore embedded database
- [x] Graphical debugger with observer-aware inspection
- [x] 817 tests

### 0.8.0

- [x] Reference counting GC, unobserved blocks, SDL2 graphics
- [x] Bitwise operations, terminal I/O, arena allocator
- [x] Fuzz testing, security hardening

### 0.7.0

- [x] Pattern matching, pipe operator, lambdas, break/continue
- [x] Regex, import system, EBNF grammar

### 0.6.0

- [x] REPL, dictionaries, closures, f-strings, try/catch, eval

### 0.5.0

- [x] Observer semantics, 121 builtins, 25 stdlib modules
- [x] HTTP, PostgreSQL, transformer extensions
