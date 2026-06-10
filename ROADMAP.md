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

DMG benchmark: ~1.094 MHz on cpu_instrs at 0.11.4 (target 4.19 MHz);
re-measure with the ROM workload before starting the next item.

- [ ] Copy-and-patch JIT — template native code gen for hot functions;
      eliminates dispatch overhead. Expected 5-10x on hot paths.
- [ ] NaN-boxing — encode numbers directly in 64-bit slots; prerequisite
      for efficient JIT. Eliminates make_num + num refcount traffic.
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
