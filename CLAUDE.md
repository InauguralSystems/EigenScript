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
- **JIT emitter invariants** (`src/jit.c`): the scanner and the
  emitter's `last_imm` switch move in lockstep; thunk bodies run at
  `%rsp ≡ 8 (mod 16)`, so every external call is wrapped in
  `push %rcx`/`pop %rcx` (and callee-saved pushes in the prologue stay
  even in number — `%r15` is pushed twice for this). Registers:
  `%rbx`=&g_vm, `%ecx`=sp cache, `%r12`=fn_env values
  (`needs_env_cache`), `%r13d`=advance, `%r14`=chunk (`has_bail_op`),
  `%r15`=&frames[fc-1] (`needs_frame_cache`).
- **jit_advance sentinels**: `-1` = thunk ran a full RETURN (vm_run
  resyncs and drops the popped frame's chunk ref); `-2` = deep bail
  from a native callee (`jit_helper_call` already left every frame's
  ip consistent — resync only, NO decref). All three thunk-invocation
  sites in vm_run (OSR, CALL, DISPATCH) must handle both.
- **Inline JIT fast paths must mirror interpreter REUSE branches
  exactly.** CASE(SET_LOCAL)'s in-place mutation of an exclusive
  untracked num is load-bearing: `g_last_observer` may alias that
  Value, and a swap+decref would free it. Same family: NUM_REUSE in
  arith (JIT bails rc==1 operands to the interpreter on purpose).
- **Inline-vs-measure trap**: EIGS_JIT_STOPS counts *compile-time*
  scan stops only. A loop that never gets a thunk (OSR slot taken,
  chunk never re-entered) or a thunk that guard-bails every iteration
  shows zero bailouts while running interpreted. When a JIT change
  measures flat, disassemble the live thunk (`EIGS_JIT_DEBUG=1
  EIGS_JIT_DUMP_NATIVE=1` + `objdump -D -b binary -m i386:x86-64`)
  and check the advance value it exits with.
- Nondet builtins use `TRACE_NONDET_RET`, or the
  `TRACE_NONDET_TAKE`/`TRACE_NONDET_RECORD` pair when the builtin does
  real work (I/O, network, bulk construction) before its return value
  exists — never let replay run the live side effects.
- The Makefile `asan` target compiles with `EIGENSCRIPT_EXT_HTTP=0`;
  if you touch `ext_http.c`, compile-check with `make http`.
- `make test` must run with stdin available or redirected from
  /dev/null — `test_terminal.eigs` blocks forever reading a pipe that
  never EOFs (e.g. backgrounded runs).

## Current focus: 0.12.0 performance

Stage 5 (a–h) is fully shipped: inline fast paths (INDEX_SET, EnvIC
name get/set, dict-dot via 2-way inline cache, tracked-num
arith/compare operands), native VAL_FN calls inside thunks, per-loop
OSR slots (`jit_osr[4]`), and the DOT_SET in-place write. Cumulative:
`bench_dmg_shape` 239 → ~118 ms (2.0×); the JIT beats `EIGS_JIT_OFF`
by ~45% on it. Design record: CHANGELOG.md (Stages 5–5h) +
`docs/JIT_STAGE5_INLINE_IC.md` (spec + as-built deltas).

Remaining 0.12.0 items (ROADMAP.md): NaN-boxing for *container*
storage (list items / dict values are still `Value**`; stack and env
slots are already EigsSlot), extending GET_LOCAL/SET_LOCAL to all
locals, and per-call env churn (`env_new`/`env_free` per call — now
the likely top DMG cost). Re-profile before picking: every stage this
cycle changed the profile shape.
