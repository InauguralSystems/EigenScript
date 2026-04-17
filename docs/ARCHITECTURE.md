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

The lexer (`tokenize()` in `eigenscript.c`) converts source text into a flat
array of tokens. EigenScript uses indentation-significant syntax — the lexer
tracks indent depth and emits INDENT/DEDENT tokens.

### Parser

The recursive-descent parser (`parse_block()`) builds a statement tree. Each
statement has a type (assignment, if, for, while, define, return, etc.) and
child expressions. Expressions use a Pratt-style precedence parser.

### Evaluator

The tree-walking evaluator (`eval_stmt()`, `eval_expr()`) executes the AST
directly. There is no bytecode compilation step. Values are tagged unions
(`EigenValue`) that can be numbers, strings, lists, dictionaries, functions, or builtins.

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

Observation has a write-time cost: `update_observer` (and its
`compute_entropy` input) runs on every assignment so interrogations
can be answered in O(1) without maintaining a history log. When user
code has a hot region it knows won't be interrogated, an `unobserved`
block skips the observer pass for assignments inside it and enables
in-place numeric mutation on dict fields and locals (`eval.c` fast
path). Arena mark/reset provides lifecycle-scoped opt-out; `unobserved`
provides statement-scoped opt-out.

## Memory

The arena allocator (`arena.c`) provides fast bump allocation for transient
computation. Scripts use `arena_mark`/`arena_reset` to reclaim memory in
bounded-computation loops (e.g., gradient computation).

Long-lived values (variables, function definitions) are allocated with
standard `malloc` and are not affected by arena resets.

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

The 25 modules in `lib/` are pure EigenScript — no C code. They are loaded at
runtime via `load_file of "lib/module.eigs"`. Path resolution searches relative
to the current working directory, then the script's directory, then the script's
parent directory.

The meta-circular interpreter (`lib/eigen.eigs`) is notable: it implements
tokenization, parsing, and evaluation of EigenScript source code in EigenScript
itself, using `eigen_run of source` as the top-level entry point.
