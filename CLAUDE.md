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
  CI enforces `detect_leaks=1`. Known limit: a fn bound by `define`
  inside the env it captures is an env↔fn refcount cycle the runtime
  can't reclaim, so closure-heavy tests exit nonzero on a LeakSanitizer
  report after fully correct output. The runner's `rc_ok` tolerates
  exactly that case and tallies it in the final summary ("NOTE: N test
  program(s)..."); any other nonzero exit — crash, assert, UBSan — fails.
  Watch that tally: a jump means a new leak.
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
- **Suite sections now gate on exit codes too** (`rc_ok` in
  run_all_tests.sh): marker-grep alone used to let a crash *after*
  correct output pass. New .eigs sections should use `check_eigs_suite`
  (rc + marker). The one tolerated nonzero exit is a LeakSanitizer
  report (known closure-cycle leaks — see the ASan bullet above).
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
  exists — never let replay run the live side effects. Known holes
  (issue #148): `proc_*`, `exec_capture`, `recv`/`try_recv`/
  `recv_timeout` are all unwrapped — replay of a proc program forks
  real children (verified).
- **New AST node → update all five compiler pre-pass walkers**, not
  just the compile switch: `collect_referenced_names_skip`,
  `collect_referenced_names`, `scan_for_captures`,
  `scan_for_interrogated`, `collect_module_names_walk`. They
  `default: break` on unknown nodes, which silently breaks closure
  capture and module-name collection for names reachable only through
  the new node (issue #156 — AST_SLICE/AST_LIST_PATTERN_ASSIGN bit
  exactly this way).
- **New CallFrame field → initialize every frame-init site**, not just
  OP_CALL/OP_DISPATCH/jit_helper_call. vm_run's base-frame setup and
  the direct `vm_execute` entry paths (`thread_entry` in builtins.c,
  `call_eigs_fn` in builtins_tensor.c, the `dispatch` builtin,
  ext_http handlers) reuse stale frame storage — `call_argc` missed
  there and defaults clobbered explicit spawn args (issue #155).
- **`f of [x]` does not spread** — the compiler spreads literal list
  args only at `count > 1`, so a 1-element list binds the *whole list*
  to the first param. For 1-arg calls to multi-param (incl. defaulted)
  functions use `f of (x)`. This breaks the obvious recursive form
  `fib of [n - 1]` the moment a defaulted param is added (issue #153).
- The Makefile `asan` target compiles with `EIGENSCRIPT_EXT_HTTP=0`;
  if you touch `ext_http.c`, compile-check with `make http`. Same for
  `ext_gfx.c` — it's in **no** default build; compile-check with
  `make gfx`. All variants land on `src/eigenscript`, so never rebuild
  one while a suite run against another is in flight.
- `make test` must run with stdin available or redirected from
  /dev/null — `test_terminal.eigs` blocks forever reading a pipe that
  never EOFs (e.g. backgrounded runs).

## Current focus: 0.13.0 language features (+ perf carryover)

0.12.0 perf is shipped. JIT Stage 5 (a–i) is the full matrix:
inline fast paths (INDEX_SET, EnvIC name get/set, dict-dot via 2-way
inline cache, tracked-num arith/compare operands), native VAL_FN
calls inside thunks, per-loop OSR slots (`jit_osr[4]`), the DOT_SET
in-place write, and per-chunk call-env recycling (5i). Cumulative:
`bench_dmg_shape` 239 → ~118 ms (2.0×); the JIT beats `EIGS_JIT_OFF`
by ~45% on it. Design record: CHANGELOG.md (Stages 5–5i) +
`docs/JIT_STAGE5_INLINE_IC.md` (spec + as-built deltas).

0.13.0 has shipped a run of language features (CHANGELOG.md
[0.13.0] for the full record): destructuring assignment, streaming
subprocess I/O (`proc_spawn` / `proc_write` / `proc_read_line` /
`proc_read` / `proc_close` / `proc_wait`), negative indexing,
slicing (`a[start:end]` half-open with defaults + negative bounds +
strict bounds-check, lists/strings/buffers), default parameter
values, non-blocking channel recv (`recv_timeout of [ch, ms]` plus
suite coverage for the pre-existing `try_recv`), `spawn` with
multiple positional args, and finite-count `audio_play_loop` (gfx).
Tidepool downstream: GAP-001 / GAP-002 finite / GAP-005 / GAP-006
all closed; GAP-002 infinite loop and GAP-003 per-channel volume
still open.

A post-merge review of the 0.13.0 run filed issues #148–#159 (all
repro'd against HEAD; suites still pass because none are crashes).
Twelve fixed so far: **#155** (`call_argc` uninitialized on vm_run
base frames; spawn/sort_by/dispatch/http defaults clobbered explicit
args), **#156** (pre-pass walkers didn't know AST_SLICE /
AST_LIST_PATTERN_ASSIGN; closure capture and module globals silently
broke), **#148** (proc_* / exec_capture / recv* now fail loudly under
`EIGS_REPLAY` — boundary documented in `docs/TRACE.md`), **#149**
(`FD_CLOEXEC` on every pipe end in proc_spawn / exec_capture so the
fds don't leak into subsequent children), **#150** (exec_capture
child resets `SIGPIPE` to `SIG_DFL` so `yes | head -1` and similar
inherited-`SIG_IGN` hang patterns drain instead of hanging), **#151**
(`recv_timeout` clamps ms before the `(long)` cast — NaN/+inf/huge
no longer produce UB or spurious deadlines; channel condvars now use
`CLOCK_MONOTONIC`), **#152** (`audio_play_loop` rejects NaN /
out-of-range / >10000 loops before the `(int)` cast, plus a 256 MiB
byte-budget gate so a modest loop count over a multi-second clip
can't queue gigabytes into SDL in one call), **#153** (docs: contract
spells out `f of [x]` non-spread + default-params footgun; behavior
unchanged, the rule below in this CLAUDE.md is now also in
LANGUAGE_CONTRACT.md), **#154** (docs: 0.13.0's `f of []` argc=0
lowering silently changed multi-param `g of []` from `a=[], b=null`
to `a=null, b=null` — change acknowledged in the contract, defaulted-
multi-param `argc<first_default` edge also pinned down), **#157**
(destructure pattern parser bracket-counts the lookahead and emits
pattern-specific errors instead of silently restoring on >64 names,
trailing comma, or non-ident targets), **#158** (OP_CALL/OP_DISPATCH
gate that left underfed-below-first_default tails unfilled — defaults
now fire for every unsupplied defaulted slot regardless of argc; the
#154 docs subtlety is gone), **#159** (new `proc_read_buf` returns a
VAL_BUFFER so an embedded NUL in child output survives; `proc_read`
documented text-only; `proc_read_line` returns the partial line on
mid-stream error instead of dropping it; `proc_write` returns the
partial byte count on error so retrying callers don't double-send).
All twelve post-merge issues closed; 0.13.0 ready to tag.

Perf carryover from 0.12.0 (ROADMAP.md): NaN-boxing for *container*
storage (list items / dict values are still `Value**`; stack and env
slots are already EigsSlot), extending GET_LOCAL/SET_LOCAL to all
locals (currently restricted; broadening unlocks JIT inline ICs on
every local), and per-call env churn (`env_new` / `env_free` per
call — likely the top DMG cost post-5i for non-recyclable
callsites). Re-profile before picking: every stage last cycle moved
the profile shape.
