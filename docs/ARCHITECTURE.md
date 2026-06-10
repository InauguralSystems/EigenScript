# Architecture

EigenScript is a bytecode-compiled language with a stack-based virtual machine,
written in C. The runtime is a single binary with no external dependencies
(minimal build) or optional extensions for HTTP, PostgreSQL, SDL2 graphics,
and transformer models (full build).

## Source Layout

```
src/
├── eigenscript.h          # Public header: types, parser, VM API
├── eigenscript.c          # Globals, value constructors, refcount GC, environment, observer
├── lexer.c                # Tokenizer
├── parser.c               # Recursive-descent parser → AST
├── compiler.c             # AST → bytecode compiler
├── vm.h                   # Opcode enum, chunk/frame/VM structs
├── vm.c                   # Bytecode VM execution loop (computed-goto dispatch) + JIT helpers
├── jit.h                  # JIT public API, layout descriptor, helper prototypes
├── jit.c                  # x86-64 template JIT: scanner, emitter, code cache
├── jit_smoke.c            # Standalone emitter smoke test (make jit-smoke)
├── chunk.c                # Bytecode container, constant pool, disassembler
├── trace.h / trace.c      # Execution trace tape, deterministic replay
├── hash.c                 # Hashing builtins (SHA-256, MD5, HMAC)
├── fmt.c                  # Code formatter
├── lint.c                 # Linter
├── eigenlsp.c             # Language server (standalone binary)
├── builtins.c             # Core builtins (I/O, collections, string, bitwise, ...)
├── builtins_tensor.c      # Tensor math, gradients, SGD
├── builtins_internal.h    # Cross-TU prototypes for tensor builtins
├── arena.c                # Arena memory allocator (mark/reset) + xalloc helpers
├── strbuf.c               # Growable string buffer helper
├── main.c                 # Entry point, CLI argument handling
├── ext_http.c             # HTTP server extension (optional)
├── ext_db.c               # PostgreSQL extension (optional)
├── ext_store.c            # EigenStore key-value database
├── ext_gfx.c              # SDL2 graphics extension (optional, dlopen'd)
├── model_io.c             # Model weight loading/saving (optional)
├── model_infer.c          # Transformer forward pass (optional)
└── model_train.c          # Training loop and gradient computation (optional)
```

## Pipeline

```
Source code (.eigs)
    │
    ▼
  Lexer          tokenize() → token array
    │
    ▼
  Parser         parse() → AST (31 node types)
    │
    ▼
  Compiler       compile_ast() → EigsChunk (bytecode + constant pool)
    │
    ▼
  VM             vm_execute() → computed-goto dispatch loop → values
    │            │
    │            ▼
    │          JIT (x86-64)   hot chunks/loops → native thunks
    ▼
  Observer       track entropy, dH, trajectory per variable
```

### Lexer

The lexer (`tokenize()` in `lexer.c`) converts source text into a flat
array of tokens. EigenScript uses indentation-significant syntax — the lexer
tracks indent depth and emits INDENT/DEDENT tokens.

### Parser

The recursive-descent parser (`parse()`) builds an AST with 31 node types.
Each node has a type (assignment, if, for, while, define, return, etc.) and
child expressions. Expressions use a Pratt-style precedence parser.

### Compiler

The compiler (`compile_ast()` in `compiler.c`) walks the AST and emits a
flat bytecode array with 60+ opcodes into an `EigsChunk`. Each chunk has:

- **Bytecode array** — compact `[op:8][arg:16LE]` encoding
- **Constant pool** — deduplicated numbers and strings
- **Line number table** — for error messages
- **Nested function chunks** — compiled function bodies

The compiler tracks stack depth at compile time to validate that each
statement and branch path maintains correct stack balance. Function
parameters are assigned local slot indices for fast access via
`OP_GET_LOCAL`/`OP_SET_LOCAL` (direct env array index, no hash lookup).

### VM

The bytecode VM (`vm_execute()` / `vm_run()` in `vm.c`) uses a single
dispatch loop with GCC computed-goto (`&&label` / `goto *table[op]`)
for the hot path, with a switch fallback for other compilers.

Key design decisions:

- **Non-recursive function calls.** `OP_CALL` pushes a new `CallFrame`
  and continues the dispatch loop. `OP_RETURN` pops the frame and
  resumes the caller. No C stack recursion — function call depth is
  limited only by `VM_FRAMES_MAX` (4096), not the C stack.

- **Env-based variable storage.** Variables are stored in `Env` hash
  tables (the same structure used pre-VM). Function parameters use
  `OP_GET_LOCAL`/`OP_SET_LOCAL` for direct slot access, bypassing
  hash lookup. Non-param variables use `OP_GET_NAME`/`OP_SET_NAME`
  with full scope-chain walk.

- **Re-entrant execution.** `vm_execute` can be called recursively
  from builtins (`load_file`, `eval`, `import`, `dispatch`). Each
  re-entrant call tracks its `base_frame` and returns to C when
  unwinding past it.

- **`fn_env` separation.** Each `CallFrame` has both `env` (current
  env, which changes during `OP_LOOP_ENV_FRESH` for-loop scoping)
  and `fn_env` (the function's original env, used by
  `OP_GET_LOCAL`/`OP_SET_LOCAL` to avoid slot collision with
  loop variables).

### JIT (x86-64)

A template JIT (`jit.c`) compiles hot bytecode into native thunks that
operate directly on the VM's thread-local state. It is an x86-64-only
tier — every other platform runs the computed-goto interpreter
unchanged, and `EIGS_JIT_OFF=1` disables it for bisection.

- **Gating.** Function chunks compile on entry once `exec_count` or
  `back_edge_count` crosses a threshold. Loops inside chunks that are
  never re-entered (one-shot module code) compile via on-stack
  replacement: the `OP_JUMP_BACK` handler hands execution to a thunk
  whose entry is the loop header. Each chunk has `jit_osr[4]` — one
  OSR slot per hot loop header, so a setup loop cannot pin the slot a
  hotter main loop needs.
- **Templates with helper fallback.** The emitter inlines fast paths
  (arithmetic and comparisons including tracked-num operands, EnvIC
  name get/set, dict-field get/set through a 2-way set-associative
  inline cache, buffer index writes) and guards each with checks that
  jump to an out-of-line C helper replicating the interpreter case
  verbatim. Anything unsupported ends the compiled prefix; the thunk
  writes a byte-advance back to the chunk so the interpreter resumes
  exactly where native execution stopped.
- **Native calls.** A compiled `VAL_FN` callee is invoked directly
  from the caller's thunk (`jit_helper_call` pushes the frame and runs
  the callee's thunk); a callee that bails mid-body hands the whole
  frame stack back to the interpreter via a `-2` advance sentinel with
  every frame's ip left consistent.
- **Diagnostics.** `EIGS_JIT_STOPS=1` (compile-stop histogram),
  `EIGS_JIT_STATS=1`, `EIGS_JIT_HOT=1`, `EIGS_JIT_DEBUG=1`
  (+`EIGS_JIT_DUMP_NATIVE=1` for hex dumps). History and design
  records live in CHANGELOG.md (Stages 4–5h) and
  `docs/JIT_STAGE5_INLINE_IC.md`.

### Observer

The observer system tracks entropy and rate-of-change for every assigned
variable. The six trajectory states are:

- **improving** — entropy is decreasing
- **diverging** — entropy is increasing
- **stable** — entropy is changing slowly
- **equilibrium** — entropy has nearly stopped changing
- **oscillating** — dH is sign-flipping
- **converged** — entropy is very low and stable

Observer state is accessible via interrogatives (`what`, `who`, `when`,
`where`, `why`, `how`) and predicates (`converged`, `stable`, etc.),
and drives `loop while not converged` termination.

Observation uses lazy evaluation: `OP_OBSERVE_ASSIGN` marks values dirty
(O(1)), and entropy is computed on demand when observer state is read.
The last observed value is tracked via a thread-local pointer
(`g_last_observer`). `unobserved` blocks skip observer marking entirely.

Loop stall detection (`OP_LOOP_STALL_CHECK`) exits while-loops after 100
consecutive iterations with `|dH| < threshold`, setting `__loop_exit__`
and `__loop_iterations__` env variables.

## Memory

EigenScript uses a hybrid memory model: reference counting, arena bump
allocation, a numeric freelist, and environment freelists.

**Reference counting.** Every heap-allocated `Value` has an atomic refcount
(`__ATOMIC_RELAXED` increment, `__ATOMIC_ACQ_REL` decrement). When the
refcount reaches zero, `free_value` tears down the value and its children.
Arena-allocated values (`v->arena == 1`) skip refcounting entirely — they
are reclaimed in bulk by `arena_reset`.

**Arena allocator.** The arena (`arena.c`) provides fast bump allocation in
16 MB blocks (up to 64 blocks). Scripts use `arena_mark`/`arena_reset` to
reclaim transient memory in bounded-computation loops.

**Numeric freelist.** Freed `VAL_NUM` values are placed in a per-thread
freelist (up to 4096 entries) and reused by `make_num`, avoiding
malloc/free churn in arithmetic-heavy loops.

**Environment freelist.** Freed `Env` structs are cached per-thread (up to
1024 entries) and reused by `env_new`, avoiding allocation in tight
function-call loops.

**Closure environments.** Environments captured by closures
(`env->captured = 1`) track a reference count (`env_refcount`, atomic).
When the last closure referencing an env is freed, the env becomes
eligible for cleanup.

## Extensions

Extensions are conditionally compiled via flags:

| Flag | Extension | Dependency |
|------|-----------|------------|
| `EIGENSCRIPT_EXT_HTTP` | HTTP server | none (uses raw sockets) |
| `EIGENSCRIPT_EXT_DB` | PostgreSQL | libpq |
| `EIGENSCRIPT_EXT_MODEL` | Transformer | none |
| `EIGENSCRIPT_EXT_GFX` | SDL2 graphics | libSDL2 (loaded at runtime via `dlopen`) |

The minimal build (`make build`) sets all flags to 0. The full build
(`make full`) enables everything.

## Standard Library

The 49 modules in `lib/` are pure EigenScript — no C code. They are loaded at
runtime via `load_file of "lib/module.eigs"`. Path resolution searches relative
to the executable's directory, then the current working directory, then the
script's directory.

The meta-circular interpreter (`lib/eigen.eigs`) implements tokenization,
parsing, and evaluation of EigenScript source code in EigenScript itself.
