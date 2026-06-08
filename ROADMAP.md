# Roadmap

Current version: **0.11.0**

## Next: Performance (0.12.0)

Based on gprof profiling of DMG (500K cycles):
- 72% vm_run dispatch, 6.5% env_hash_find, 5% env_set_local_hashed,
  3.6% env_free, 2.2% make_num. 60K re-entrant vm_execute calls.

- [ ] Eliminate dispatch builtin re-entry (60K vm_execute calls → use OP_CALL directly)
- [ ] Extend GET_LOCAL/SET_LOCAL to all local variables (not just params)
- [ ] Reduce env_free churn from LOOP_ENV_FRESH (3.9M frees per 500K cycles)
- [ ] In-place numeric mutation for refcount-1 values (3.7M make_num calls)
- [ ] Dict field inline caching (OP_DOT_GET with cached slot offset)
- [ ] Benchmark DMG target: 0.5+ MHz (currently 0.177 MHz)

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
