# Roadmap

Current version: **0.11.8**

Recently shipped (0.11.5–0.11.8): cross-platform CI + sanitizer matrix,
HTTP server hardening (threaded accept, protocol hygiene), execution
trace tape + deterministic replay (`EIGS_TRACE`/`EIGS_REPLAY`), temporal
interrogatives (`prev of`, `at`, `state_at` + line-floor index),
debugger step-back, leak-clean suite under ASan (enforced in CI), and
refcounted bytecode chunks.

## Next: Performance (0.12.0)

Fresh profile (gprof, post-0.11.8, `tests/bench_dmg_shape.eigs` —
500k dispatch-table steps; the DMG ROM workload itself lives outside
the repo):

- First finding (fixed): the 0.11.7 reversibility machinery ran
  unconditionally — 17.8M `trace_line` + 2.5M `trace_assign` calls per
  500k steps, ~1/3 of runtime. History recording is now compile-gated
  (`g_trace_hist`); the workload dropped 295 → 243 ms and the
  micro-benches 20–57%.
- Post-fix profile: ~65% vm_run dispatch (structural — JIT territory),
  then env churn (`env_free` 2.58M calls ≈ one per fn call,
  `env_set_local`/`slot_from_value` 0.57M, `env_hash_find` 1.3M) and
  `make_num` traffic (2.1M calls).

DMG benchmark: **target met** — ~5 MHz on cpu_instrs at 0.11.8
(5.11 MHz over 5M cycles, 4.80 MHz sustained over 30M; target was
4.19 MHz real-hardware speed; was 1.094 MHz at 0.11.4). Remaining
0.12.0 items are for headroom and for non-DMG workloads.

- [x] **JIT Stage 5 — inline the hot fast paths.** Buffer-INDEX_SET
      and GET_NAME/SET name EnvIC fast paths now emit as native
      templates with helper fallback on guard failure, plus a
      (env, binding_version, slot) write cache for the per-iteration
      `__loop_iterations__` update. bench_dmg_shape 239→218 ms,
      bench_idxset 29.7→24.6 ms; isolation probes 2.8–3.4×. Spec in
      `docs/JIT_STAGE5_INLINE_IC.md` (status updated in place).
- [x] **JIT Stage 5d — inline dict-dot fast paths.** LOCAL_DOT_GET/SET
      cache-hit paths emit inline (baked hash, interned-key pointer
      equality, in-place num mutate); helper fallback repopulates the
      dict cache. Isolated dict-RMW loop −31% (65→45 ms).
- [x] **JIT Stage 5e — tracked-num operands in arith/compare
      templates.** Root cause refined: CASE(SET_LOCAL)'s in-place
      branch mutates an observed-then-unobserved counter's tracked
      Value forever (pointer identity preserved by design — and
      g_last_observer may alias it), so native arith/compare bailed on
      it every iteration. ADD/SUB/MUL/DIV/MOD and all six comparisons
      now accept heap/tracked VAL_NUM operands (refcount ≥ 2; rc==1
      routes to the interpreter so NUM_REUSE keeps its in-place
      semantics), with post-commit operand decrefs and a branched
      commit that keeps the imm/imm path at pre-5e cost. The JIT
      SET_LOCAL template gained the interpreter's exact in-place
      branch (required: the swap path would free a Value
      g_last_observer can still point at). Poisoned-counter loop
      −26% (141→105 ms); bench_idxset −10% (24.6→22.2 ms).
- [ ] **VAL_FN calls inside thunks.** The remaining bench_dmg_shape
      cap: `handler of ctx` makes OP_CALL bail (helper handles
      builtins only), and the interpreter then runs the REST of the
      loop iteration before the back-edge re-enters the OSR thunk —
      so every iteration is part native, part interpreted. Needs
      native frame push/handoff for VAL_FN/VAL_CLOSURE targets, or a
      thunk-resume point after the call.
- [ ] NaN-boxing for container storage — stack and env slots are
      already EigsSlot/NaN-boxed; list items and dict values are still
      `Value**`, so every list/dict number write round-trips through
      make_num + refcounts (2.1M make_num calls in the DMG profile).
      Encode immediates directly in list/dict storage. Big surface
      (every `data.list.items` / `data.dict.vals` touch site).
- [ ] Extend GET_LOCAL/SET_LOCAL to all local variables (closure-safe)
- [ ] Reduce env_free churn from LOOP_ENV_FRESH

### Language features (0.13.0)

- [ ] Destructuring assignment (`[a, b] is [1, 2]`)
- [ ] Streaming subprocess I/O (stdin pipe, unbuffered stdout)
- [ ] Negative indexing + slicing (`a[-1]`, `s[1:3]`) — one coherent addition;
      committed semantics (from-end, half-open `[start:end)`, raise on OOB bounds)
      reserved in `docs/LANGUAGE_CONTRACT.md`
- [ ] Default parameter values

### Ecosystem

- [ ] Package manager / module registry
- [ ] More STEM modules (graph theory, regression, numerical PDEs)
- [ ] WASM compilation target
- [ ] Foreign function interface (FFI) for calling C libraries

### Long-term

- [ ] Self-hosting compiler (EigenScript written in EigenScript)
- [ ] GitHub Linguist submission (requires 2K+ .eigs files across repos)
- [ ] Public release

## Completed

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
