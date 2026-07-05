# EigenScript documentation map

Start here. Each document has a stable filename and stable headings —
link to sections freely.

**Try it in your browser:** [playground/](playground/) — interpreter-only
WASM build, no install required.

## Learn the language

| document | what it answers |
|---|---|
| [SPEC.md](SPEC.md) | **The canonical spec.** Every construct with a runnable example and its exact output — all examples are executed by the test suite, so the spec cannot drift from the implementation. |
| [SYNTAX.md](SYNTAX.md) | Tutorial-style guide to the same material, in prose. |
| [COMPARISON.md](COMPARISON.md) | EigenScript next to Python / JavaScript / Rust / Lisp, with a porting checklist and before/after transformations (also executed by the suite). |
| [GRAMMAR.md](GRAMMAR.md) | The formal grammar. |
| [LANGUAGE_CONTRACT.md](LANGUAGE_CONTRACT.md) | Edge-case promises: exactly what is guaranteed at the boundaries (argument spreading, coercion, subprocess I/O, ...). |

## Reference

| document | what it answers |
|---|---|
| [BUILTINS.md](BUILTINS.md) | Every built-in function: signature, behavior, errors. |
| [STDLIB.md](STDLIB.md) | The 73 standard-library modules under `lib/`. |
| [OBSERVER.md](OBSERVER.md) | Observer semantics in depth: entropy, dH, predicates, `unobserved`. |
| [TRACE.md](TRACE.md) | Temporal interrogatives, the trace tape, deterministic replay, and replay's nondeterminism boundary. |
| [DIAGNOSTICS.md](DIAGNOSTICS.md) | Error messages, the linter, and the formatter. |

## Internals

| document | what it answers |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Pipeline overview: lexer → parser → bytecode compiler → stack VM → copy-and-patch JIT. |
| [EMBEDDING.md](EMBEDDING.md) | C embedding API (`src/eigs_embed.h`): lifecycle, eval, error retrieval, value handles, FFI. |
| [JIT_STAGE5_INLINE_IC.md](JIT_STAGE5_INLINE_IC.md) | The JIT's inline fast paths and caches: design + as-built record. |
| [CLOSURE_CYCLE_GC.md](CLOSURE_CYCLE_GC.md) | The closure-cycle collector: honest env refcounts, the registry/mark-sweep design as built, maintainer invariants, and what still leaks. |
| [TEST_COVERAGE_ANALYSIS.md](TEST_COVERAGE_ANALYSIS.md) | The coverage program: findings → fixes → residual gaps, with measured numbers. |
| [GAP_ANALYSIS.md](GAP_ANALYSIS.md) | Downstream feature-gap tracking. |
| [PACKAGE_SPEC.md](PACKAGE_SPEC.md) | The `--pkg` tool as implemented: `add`/`install`/`update`/`verify`/`list`, `eigs.json` manifest, SHA-pinned lockfile, vendored `eigs_modules/`. |
| [PACKAGE_DESIGN.md](PACKAGE_DESIGN.md) | Partially implemented — shipped behavior lives in PACKAGE_SPEC.md; the design intent and open questions are here. |

## Editor support

[`editors/vscode/`](../editors/vscode/) (TextMate grammar + language
config) and [`editors/vim/`](../editors/vim/) (syntax + ftdetect);
`make lsp` builds the language server (`src/eigenlsp` — diagnostics,
completion, hover, definition, references over stdio).

## Examples

- [`examples/`](../examples/) — 50+ runnable programs, smoke-tested by
  the suite, from `hello.eigs` to a Conway's-Life and STEM simulations.
- [`examples/errors/`](../examples/errors/) — programs that *fail on
  purpose*, each declaring its expected error message in an
  `# expect-error:` header (verified by the suite). Read these to learn
  what mistakes look like.
- [`tests/`](../tests/) — the language's executable semantics: 2,500+
  checks, each test file readable as a statement of intended behavior.

## Conventions in these docs

- ` ```eigenscript ` fenced blocks followed by an ` ```output ` block
  are **executed and checked** by `tests/test_doc_examples.py`.
- ` ```eigenscript skip ` marks valid syntax that is deliberately not
  executed (nondeterministic or environment-dependent).
- Code without an output block is an illustrative fragment.
