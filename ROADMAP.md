# Roadmap

Current version: **0.9.3**

## Near-term

- [ ] Streaming subprocess I/O (stdin pipe, unbuffered stdout)
- [ ] More STEM modules (graph theory, regression/curve fitting, numerical PDEs)

## Medium-term

- [ ] WASM compilation target
- [ ] Destructuring assignment
- [ ] Package manager / module registry
- [ ] Optimizing JIT backend

## Long-term

- [ ] Self-hosting compiler (EigenScript written in EigenScript)
- [ ] Foreign function interface (FFI) for calling C libraries

## Completed (0.9.3)

- [x] Computational geometry library (EigenScript's namesake) — 60+ functions, convex hull, transforms
- [x] Lab data collection framework — experiment management with observer-aware measurement analysis
- [x] Tunable observer thresholds (`set_observer_thresholds`) for advanced convergence studies
- [x] 15 STEM simulation examples (orbital mechanics, climate model, genetic drift, etc.)
- [x] 49 stdlib modules, 14 STEM

## Completed (0.9.2)

- [x] STEM standard library — 12 modules: physics, chemistry, biology, engineering, earth_science, linalg, calculus, probability, optimize, simulation, numerics, experiment
- [x] Observer-aware computation — optimization, simulation, iterative methods, and experimental analysis that leverage EigenScript's native convergence detection
- [x] SDL2 audio extension — synthesis (sine/saw/square/noise), playback, mixing, ADSR envelope
- [x] Code formatter (`--fmt`) and linter (`--lint`) built into binary
- [x] Valgrind leak fix (2MB → 1.8KB per run), shellcheck clean test runner
- [x] Tidepool near-parity: creature system, combat, mating, editor, camera zoom, particles, high scores

## Completed (0.9.1)

- [x] Language server protocol (LSP) — eigenlsp binary, VS Code extension
- [x] Hashing builtins — SHA-256, MD5, HMAC-SHA256, file hashing
- [x] Column tracking in tokens and AST nodes

## Completed (0.9.0)

- [x] UI toolkit — 44 widgets, 3 themes, flex layout, animation, keyboard navigation
- [x] Real concurrency — thread-local globals, `spawn`/`thread_join`, channels
- [x] EigenStore — zero-dependency native embedded database
- [x] Data library — DataFrame operations (df_from_csv, df_select, df_where, df_join, etc.)
- [x] Statistics library — mean, median, std_dev, histogram, correlation, describe
- [x] Graphical debugger with observer-aware variable inspection
- [x] Meta-circular interpreter at full language parity (dicts, lambdas, imports, observer)
- [x] Index-assignment syntax (`list[i] is val`, `dict[key] is val`)
- [x] SDL2 enhancements (rounded rects, clip rects, mouse wheel, modifier keys, window resize)
- [x] 817 tests, eval.c at 96.6% coverage

## Completed (0.8.0)

- [x] Reference counting garbage collection
- [x] `unobserved:` blocks — opt-out of observer tracking, in-place numeric mutation
- [x] SDL2 graphics extension (13 builtins: window, shapes, text, events, timing)
- [x] Bitmap font text rendering (`gfx_text`)
- [x] Bitwise operations (`bit_and`, `bit_or`, `bit_xor`, `bit_not`, `bit_shl`, `bit_shr`)
- [x] Terminal I/O (`write`, `flush`, `raw_key`, `usleep`)
- [x] `join` as C builtin (O(n) string concatenation)
- [x] `monotonic_ns` / `monotonic_ms` — high-resolution monotonic timer
- [x] System stdlib resolution (`~/.local/lib/eigenscript/`)
- [x] `make install` installs stdlib alongside binary
- [x] Gap analysis document (`docs/GAP_ANALYSIS.md`)
- [x] Source split: `eigenscript.c` → `lexer.c`, `parser.c`, `eval.c`, `builtins.c`
- [x] Security hardening (strbuf, OOM-safe alloc, recursion guard, softmax NaN guard)
- [x] Fuzz testing infrastructure (44 edge case + adversarial tests under ASAN+UBSan)

## Completed (0.7.0)

- [x] Pattern matching (`match`/`case` with wildcard `_`)
- [x] Pipe operator (`|>`)
- [x] Lambda expressions (`(x) => x * 2`)
- [x] Break/continue in loops
- [x] Dot-assignment on dicts (`config.name is "value"`)
- [x] Multiline collections (lists and dicts span multiple lines)
- [x] Regex builtins (`regex_match`, `regex_find`, `regex_replace` — POSIX ERE)
- [x] Import system with namespacing (`import math`)
- [x] Formal EBNF grammar specification (`docs/GRAMMAR.md`)
- [x] 371 → 568 tests

## Completed (0.6.0)

- [x] REPL (interactive mode)
- [x] Native dictionary type with `{}` syntax and `.key` access
- [x] First-class closures
- [x] Named function parameters (`define add(a, b) as:`)
- [x] String interpolation (`f"hello {name}"`)
- [x] Try/catch error handling + `throw` builtin
- [x] `eval` builtin
- [x] Meta-circular interpreter (`lib/eigen.eigs`)

## Completed (0.5.0)

- [x] Observer semantics with 6 trajectory states
- [x] Interrogative operators (what/who/when/where/why/how)
- [x] 121 builtins across core, tensor, I/O, and extension modules
- [x] 25 standard library modules
- [x] Arena memory allocator
- [x] HTTP server extension
- [x] PostgreSQL extension
- [x] Transformer model extension (inference + training)
- [x] Full documentation (syntax, builtins, stdlib, diagnostics)
