# Roadmap

Current version: **0.8.1**

## Near-term

- [ ] Package manager / module registry for third-party `.eigs` libraries
- [ ] Debugger with step/inspect/breakpoint support
- [ ] Source maps for error traces across `load_file` boundaries
- [ ] Streaming subprocess I/O (stdin pipe, unbuffered stdout)

## Medium-term

- [ ] Concurrency primitives (channels, spawn)
- [ ] WASM compilation target
- [ ] Destructuring assignment
- [ ] SQLite extension
- [ ] Hashing builtins (SHA-256, MD5)

## Long-term

- [~] Self-hosting (meta-circular interpreter in `lib/eigen.eigs` — partially complete)
- [ ] Self-hosting compiler (EigenScript written in EigenScript)
- [ ] Language server protocol (LSP) for editor integration
- [ ] Optimizing JIT backend
- [ ] Foreign function interface (FFI) for calling C libraries

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
