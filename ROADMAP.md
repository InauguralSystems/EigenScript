# Roadmap

Current version: **0.6.0**

## Near-term

- [ ] Package manager / module registry for third-party `.eigs` libraries
- [ ] Debugger with step/inspect/breakpoint support
- [ ] Source maps for error traces across `load_file` boundaries

## Medium-term

- [ ] Pattern matching / destructuring assignment
- [ ] Concurrency primitives (channels, spawn)
- [ ] WASM compilation target

## Long-term

- [~] Self-hosting (meta-circular interpreter in `lib/eigen.eigs` — partially complete)
- [ ] Self-hosting compiler (EigenScript written in EigenScript)
- [ ] Language server protocol (LSP) for editor integration
- [ ] Optimizing JIT backend
- [ ] Foreign function interface (FFI) for calling C libraries

## Completed (0.6.0)

- [x] REPL (interactive mode)
- [x] Native dictionary type
- [x] First-class closures
- [x] Named parameters
- [x] String interpolation
- [x] Try/catch error handling
- [x] `eval` builtin
- [x] Meta-circular interpreter (`lib/eigen.eigs`)
- [x] Observer semantics with 6 trajectory states
- [x] 127 builtins across core, tensor, I/O, and extension modules
- [x] 25 standard library modules
- [x] Arena memory allocator
- [x] HTTP server extension
- [x] PostgreSQL extension
- [x] Transformer model extension (inference + training)
- [x] Full documentation (syntax, builtins, stdlib, diagnostics)
- [x] 121-test compliance suite
