# CLAUDE.md — EigenScript working guide

EigenScript is a C-implemented language runtime: lexer → parser →
bytecode compiler → stack VM (computed-goto dispatch) with a
copy-and-patch x86-64 JIT, an observer system (entropy/dH tracking on
every assignment), and a reversibility layer (temporal interrogatives,
trace tape, deterministic replay).

## Build & test

```
make            # release build -> src/eigenscript (HTTP/MODEL/DB off)
make test       # build + full suite (tests/run_all_tests.sh)
make asan       # ASan+UBSan build (same binary path!)
make http       # http+model variant — run tests/test_http_server.sh
make jit-smoke  # standalone emitter tests (jit_smoke.c stubs all helpers)
```

- The suite must pass **both** release and ASan with leaks on:
  `make asan && cd tests && ASAN_OPTIONS=detect_leaks=1 bash run_all_tests.sh`
  CI enforces `detect_leaks=1`; any new leak fails the build.
- `make asan` overwrites `src/eigenscript` — rebuild with `make`
  before timing anything.
- Benchmarks: `tests/bench_perf.eigs` (micro), `tests/bench_dmg_shape.eigs`
  (dispatch-table interpreter shape, the DMG/cpu_instrs stand-in),
  `tests/bench_idxset.eigs` (fn-local buffer/list write loop — compiles
  to a single JIT thunk with zero bailouts).
- JIT diagnostics: `EIGS_JIT_STOPS=1` (bailout-opcode histogram — this
  drives coverage work), `EIGS_JIT_STATS=1`, `EIGS_JIT_HOT=1`.

## Hard-won rules (violations have bitten before)

- **Refcounts**: `env_set_local`, `list_append`, `dict_set` incref
  internally. Storing a freshly made value? Use the adopting variants
  `env_set_local_owned` / `list_append_owned` / `dict_set_owned`, or
  decref after storing. The bare `store(make_x(...))` idiom is a leak.
- **Chunks are refcounted** (creator + per-VAL_FN + per-call-frame).
  `chunk_free` = drop creator ref. JIT return thunks write
  `chunk->jit_advance` *after* `jit_helper_return` — the popped
  frame's chunk ref is dropped in vm_run's `-1` sentinel handlers,
  never in the helpers.
- **Trace gating**: `g_trace_hist` (assignment history) and
  `g_trace_obs_hist` (observer snapshots) are compiler-set flags —
  recording is off unless the program contains a temporal query
  (`prev of`, `at`, `state_at`) or `EIGS_TRACE` is set. Don't add
  always-on per-assign work; it cost ~1/3 of dispatch-heavy runtime
  once before.
- **`tests/test_temporal.eigs` is line-number-sensitive** — its `at`
  queries hardcode line numbers. Append only before the final if/else,
  and re-verify the `grep -n` markers in the file.
- **Suite checks mostly grep output and ignore exit codes** — a crash
  *after* correct output passes. For teardown/exit bugs, assert `rc=0`
  explicitly (see suite check [71]).
- **New JIT helpers need stubs in `src/jit_smoke.c`** or `make
  jit-smoke` fails to link.
- Nondet builtins use `TRACE_NONDET_RET`, or the
  `TRACE_NONDET_TAKE`/`TRACE_NONDET_RECORD` pair when the builtin does
  real work (I/O, network, bulk construction) before its return value
  exists — never let replay run the live side effects.
- The Makefile `asan` target compiles with `EIGENSCRIPT_EXT_HTTP=0`;
  if you touch `ext_http.c`, compile-check with `make http`.

## Current focus: 0.12.0 performance

JIT opcode *coverage* is done (Stage 4v/4w/4x): hot loops compile to
single thunks with zero bailouts, but timings are flat because
out-of-line helper calls cost about what computed-goto dispatch did.
**The next stage is inlining the hot fast paths as native templates**
— full implementation spec in `docs/JIT_STAGE5_INLINE_IC.md`. Read it
before touching `src/jit.c`.
