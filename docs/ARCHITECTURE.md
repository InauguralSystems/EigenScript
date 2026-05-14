# Architecture

EigenScript is a tree-walking interpreter written in C. The runtime is a single
binary with no external dependencies (minimal build) or optional extensions for
HTTP, PostgreSQL, and transformer models (full build).

## Source Layout

```
src/
├── eigenscript.h          # Public header: types, parser, evaluator API
├── eigenscript.c          # Globals, value constructors, refcount GC, environment
├── lexer.c                # Tokenizer
├── parser.c               # Recursive-descent parser
├── eval.c                 # Tree-walking evaluator + observer
├── builtins.c             # Core builtins (I/O, collections, string, bitwise, ...)
├── builtins_tensor.c      # Tensor math, gradients, SGD
├── builtins_internal.h    # Cross-TU prototypes for tensor builtins
├── arena.c                # Arena memory allocator (mark/reset) + xalloc helpers
├── strbuf.c               # Growable string buffer helper
├── main.c                 # Entry point, CLI argument handling
├── ext_http.c             # HTTP server extension (optional)
├── ext_http_internal.h    # HTTP internals
├── ext_db.c               # PostgreSQL extension (optional)
├── ext_db_internal.h      # Database internals
├── ext_gfx.c              # SDL2 graphics extension (optional, dlopen'd)
├── model_io.c             # Model weight loading/saving (optional)
├── model_infer.c          # Transformer forward pass (optional)
├── model_train.c          # Training loop and gradient computation (optional)
└── model_internal.h       # Model internals
```

## Pipeline

```
Source code (.eigs)
    │
    ▼
  Lexer          tokenize() → token array
    │
    ▼
  Parser         parse_block() → AST (statement tree)
    │
    ▼
  Evaluator      eval_stmt() / eval_expr() → values
    │
    ▼
  Observer        track entropy, dH, trajectory per variable
```

### Lexer

The lexer (`tokenize()` in `lexer.c`) converts source text into a flat
array of tokens. EigenScript uses indentation-significant syntax — the lexer
tracks indent depth and emits INDENT/DEDENT tokens.

### Parser

The recursive-descent parser (`parse_block()`) builds a statement tree. Each
statement has a type (assignment, if, for, while, define, return, etc.) and
child expressions. Expressions use a Pratt-style precedence parser.

### Evaluator

The tree-walking evaluator (`eval_node()`) executes the AST directly. There is
no bytecode compilation step. Values are tagged unions (`Value`) that can be
numbers, strings, lists, dictionaries, functions, or builtins.

Numeric values pass through `num_guard` at construction and numeric fast-path
boundaries. The runtime invariant is that user-visible numbers are finite:
`NaN` collapses to `0`, and overflow or infinity saturates at `+/-1e308`.
Scalar arithmetic, tensor arithmetic, `num` conversion, reassignment fast
paths, and `unobserved` numeric mutation all preserve this invariant.

### Observer

The observer system is embedded in the evaluator. Every variable assignment
updates the variable's observer state: entropy (information content), dH (rate
of change), and trajectory classification. The six states are:

- **improving** — entropy is decreasing
- **diverging** — entropy is increasing
- **stable** — entropy is changing slowly
- **equilibrium** — entropy has nearly stopped changing
- **oscillating** — dH is sign-flipping
- **converged** — entropy is very low and stable

Observer state is accessible from EigenScript via `report of x` and
`observe of x` builtins, and drives `loop while not converged` termination.

Observation uses lazy evaluation: assignments mark values dirty (O(1)),
and entropy is computed on demand when observer state is read
(interrogation, predicate check, `report`, or loop stall detection).
The in-place numeric fast path eagerly computes entropy since it is
O(1) for numbers. The last observed value is tracked via a thread-local
pointer (`g_last_observer`) rather than an environment binding, avoiding
hash lookups and refcount overhead on every assignment. When user code
has a hot region it knows won't be interrogated, an `unobserved` block
skips observer marking entirely and enables in-place numeric mutation
on dict fields and locals (`eval.c` fast path). Arena mark/reset
provides lifecycle-scoped opt-out; `unobserved` provides
statement-scoped opt-out.

## Memory

EigenScript uses a hybrid memory model: reference counting, arena bump
allocation, a numeric freelist, and scratch stacks.

**Reference counting.** Every heap-allocated `Value` has an atomic refcount
(`__ATOMIC_RELAXED` increment, `__ATOMIC_ACQ_REL` decrement). When the
refcount reaches zero, `free_value` tears down the value and its children.
Arena-allocated values (`v->arena == 1`) skip refcounting entirely — they
are reclaimed in bulk by `arena_reset`.

**Arena allocator.** The arena (`arena.c`) provides fast bump allocation in
16 MB blocks (up to 64 blocks). Scripts use `arena_mark`/`arena_reset` to
reclaim transient memory in bounded-computation loops (e.g., gradient
updates). If the block limit is exceeded, the arena falls back to `xcalloc`
and tracks the fallback pointers so `arena_reset` can free them. At program
exit, `arena_destroy` frees all blocks.

**Allocation invariant.** A heap-owned value (`arena == 0`) has all interior
pointers (strings, item arrays) on the heap. `list_append` and
`env_set_local` use the owning structure's allocation origin — not the
global `g_arena.active` flag — to decide where to allocate growth.

**Numeric freelist.** Freed `VAL_NUM` values are placed in a per-thread
freelist (up to 4096 entries) and reused by `make_num`, avoiding
malloc/free churn in arithmetic-heavy loops.

**Dict hash table.** Dicts use the same FNV-1a open-addressing hash
(`EnvHash`) as environments, giving O(1) key lookup, insert, and update.

**Closure environments.** Environments captured by closures
(`env->captured = 1`) track a reference count (`env_refcount`, atomic).
When the last closure referencing an env is freed, the env becomes
eligible for cleanup. Cycles (function stored in its own closure env) are
broken by nulling `fn.closure` before decrementing the env refcount.

**Thread safety.** Values sent through channels are shared by reference
(incref'd, not deep-copied). Mutable containers (dicts, lists) must not be
mutated concurrently by sender and receiver.

## Extensions

Extensions are conditionally compiled via flags:

| Flag | Extension | Dependency |
|------|-----------|------------|
| `EIGENSCRIPT_EXT_HTTP` | HTTP server | none (uses raw sockets) |
| `EIGENSCRIPT_EXT_DB` | PostgreSQL | libpq |
| `EIGENSCRIPT_EXT_MODEL` | Transformer | none |
| `EIGENSCRIPT_EXT_GFX` | SDL2 graphics | libSDL2 (loaded at runtime via `dlopen`) |

The minimal build (`./build.sh`) sets all flags to 0. The full build
(`./build.sh full`) enables everything.

## Standard Library

The 49 modules in `lib/` are pure EigenScript — no C code. They are loaded at
runtime via `load_file of "lib/module.eigs"`. Path resolution searches relative
to the current working directory, then the script's directory, then the script's
parent directory.

The meta-circular interpreter (`lib/eigen.eigs`) is notable: it implements
tokenization, parsing, and evaluation of EigenScript source code in EigenScript
itself, using `eigen_run of source` as the top-level entry point.
