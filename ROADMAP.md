# Roadmap

Current version: **0.5.0**

## Near-term

- [ ] Package manager / module registry for third-party `.eigs` libraries
- [ ] REPL (interactive mode)
- [ ] Debugger with step/inspect/breakpoint support
- [ ] Source maps for error traces across `load_file` boundaries

## Medium-term

- [ ] Pattern matching / destructuring assignment
- [ ] First-class closures
- [ ] Native dictionary type (beyond `lib/map.eigs`)
- [ ] Concurrency primitives (channels, spawn)
- [ ] WASM compilation target

## Long-term

- [ ] Self-hosting compiler (EigenScript written in EigenScript)
- [ ] Language server protocol (LSP) for editor integration
- [ ] Optimizing JIT backend
- [ ] Foreign function interface (FFI) for calling C libraries

## Completed (0.5.0)

- [x] Observer semantics with 6 trajectory states
- [x] 121 builtins across core, tensor, I/O, and extension modules
- [x] 24 standard library modules
- [x] Arena memory allocator
- [x] HTTP server extension
- [x] PostgreSQL extension
- [x] Transformer model extension (inference + training)
- [x] Full documentation (syntax, builtins, stdlib, diagnostics)
- [x] 121-test compliance suite
