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
  CI enforces `detect_leaks=1`. The env↔fn closure cycle is reclaimed by
  the cycle collector (docs/CLOSURE_CYCLE_GC.md); section [87]
  (test_closure_cycles.eigs) is gated **strictly** leak-clean — a
  LeakSanitizer exit there is a collector regression. The runner's
  `rc_ok` still tolerates LeakSanitizer exits elsewhere and tallies them
  ("NOTE: N test program(s)..."): currently 13, all spawn-thread
  programs (collector off once multithreaded) plus pre-existing
  non-closure shapes. Any other nonzero exit — crash, assert, UBSan —
  fails. Watch that tally: a jump means a new leak.
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
  report (spawn-thread programs + known non-closure shapes — see the
  ASan bullet above; section [87] deliberately opts out of that
  tolerance).
- **Env refcounts are honest and the cycle collector depends on it**:
  every owner of an `Env` — frame/creator, closure (`make_fn`), child
  env (`parent` is an owned edge), parked `chunk->env_cache` — holds a
  counted ref via `env_incref`/`env_decref`. Never stash a bare `Env*`
  that outlives its creator. The collector's `GC_FOR_EACH_CHILD` walker
  and `gc_clear_node` (eigenscript.c) must move in lockstep with the
  ownership model: a new owning edge out of Value/Env/Chunk goes into
  both, and only *counted* edges may be traversed (an uncounted edge
  trips the accounting abort and collection silently stops working).
  Conservative direction: missing an edge leaks; inventing one frees
  live memory.
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

## Current state: 0.13.0 released + closure-cycle collector; next up

0.13.0 is cut (CHANGELOG.md [0.13.0] is the full record). Landed since,
unreleased: the **closure-cycle collector** — honest `Env` refcounts
(creator/frame + closures + parent links + parked env_cache all
counted; `env_free` → `env_incref`/`env_decref`) plus a registry-driven
mark-sweep over captured envs (docs/CLOSURE_CYCLE_GC.md is the as-built
record, including the maintainer invariants). Escaping closures are
reclaimed mid-run and at exit; closure churn is ~40% faster with flat
RSS; disabled once spawn() goes multithreaded. 0.13.0 highlights on
top of the language-features run (destructuring, slicing, negative
indexing, default params, streaming subprocess I/O, recv_timeout,
multi-arg spawn) and the twelve post-merge fixes (#148–#159):

- **Structured errors**: `throw` preserves the thrown value (catch
  binds dicts/lists unchanged; runtime errors bind message strings);
  uncaught errors print a stack trace (`vm_print_stack_trace`, frame
  lines from the chunk line tables). `g_error_value` is the stash —
  cleared by runtime_error, consumed by CHECK_ERROR's catch-bind,
  released in main/thread_entry on the uncaught path.
- **Modules**: `import name` namespaces (dict binding, `_` names
  private) and falls back from `lib/name.eigs` to script-relative
  `name.eigs` for user modules. `load_file` stays the non-namespaced
  form.
- **Buffer stores keep the full double** — all four INDEX_SET arms and
  the JIT inline store used to truncate to int, diverging from buf_set.
- **Executable docs**: docs/SPEC.md + docs/COMPARISON.md example/output
  pairs are run by `tests/test_doc_examples.py` (suite [89]) and must
  match byte-for-byte. **A semantics change must update the spec in the
  same PR or CI fails.** `examples/errors/` expect-error headers are
  enforced the same way ([90]). Doc examples must not assume the temp
  dir is /tmp (macOS: /var/folders/...) — the checker runs each example
  with cwd = its own script dir.
- **Tooling**: editors/vscode + editors/vim grammars; GitHub Pages docs
  site (pages.yml; STDLIB's `{{...}}` examples are raw-wrapped for
  Liquid); LSP emits real diagnostics via `eigs_record_first_error`.
- **Releases**: push a `v*` tag *or* dispatch the Release workflow
  (Actions → Release → Run workflow), which creates the tag itself and
  builds in the same run. Note: this remote environment's git proxy
  cannot push tags, and GITHUB_TOKEN-pushed tags don't retrigger
  workflows — hence the dispatch path.

Suite: ~1832 checks; must pass release **and** ASan with
detect_leaks=1 (the leak tally — currently 13, spawn-thread programs +
pre-existing non-closure shapes — is the gate; a jump means a new
leak, and section [87] must stay strictly leak-clean).

Open items, in rough priority (current goal: be a *good MIT-licensed
language* — the legal/hygiene side is done; the gaps are distribution,
portability, and the ecosystem story):

1. **Distribution** — highest value-per-effort, no runtime changes:
   macOS release binaries (x86_64 + arm64; arm64 is interpreter-only
   until the ARM64 JIT exists) added to the Release workflow, then a
   Homebrew tap/formula. Follow-ons: Docker image, AUR, asdf/mise
   plugin. Release assets already carry sha256 digests; a CHECKSUMS
   file / artifact attestation is the next trust step.
2. **Package/dependency story** for EigenScript code itself: `import`
   resolves lib/ + script-relative only — no third-party dependency
   mechanism, no versioning, no lockfile convention. The biggest gap
   between "neat project" and "usable language"; needs a design pass
   before code.
3. **Stability contract**: pre-1.0 with no stated compat policy. Write
   the paragraph (SPEC.md or README): what's frozen, what may break
   before 1.0, how deprecations work. The executable spec (suite [89])
   is already the enforcement mechanism.
4. **`make lsp` fails on macOS runners** (skipped cleanly by the suite;
   add the compile check to the macOS CI leg to surface the error).
5. **Windows port** (runtime is POSIX-only) and **ARM64 JIT** (Apple
   Silicon runs interpreter-only) — the two real porting projects.
6. **Trust/identity follow-ons**: OSS-Fuzz enrollment (fuzz harness
   already exists — natural fit), OpenSSF Best Practices badge,
   upstream a Linguist grammar (editors/vscode has the TextMate
   grammar ready; Linguist has usage-volume requirements, so this
   waits on adoption — `.gitattributes` maps `.eigs` to Python as the
   stopgap). A browser playground via a WASM interpreter-only build
   (JIT compiled out — the build flags already support that shape) is
   the highest-leverage adoption item when the time comes.
- Perf carryover from 0.12.0 (ROADMAP.md): NaN-boxing for *container*
  storage, extending GET_LOCAL/SET_LOCAL to all locals, per-call env
  churn. Re-profile before picking: every stage last cycle moved the
  profile shape.
