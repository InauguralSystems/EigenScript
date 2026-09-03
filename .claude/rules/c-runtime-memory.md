---
paths:
  - "src/**/*.c"
  - "src/**/*.h"
---

# C runtime: refcount, ownership, and stack rules

Violations here have bitten before, and most fail silently (a leak per
iteration, or a collector that quietly stops working).

- **Refcounts**: `env_set_local`, `list_append`, `dict_set` incref
  internally. Storing a freshly made value? Use the adopting variants
  `env_set_local_owned` / `list_append_owned` / `dict_set_owned`, or
  decref after storing. The bare `store(make_x(...))` idiom is a leak.
- **Chunks are refcounted** (creator + per-VAL_FN + per-call-frame).
  `chunk_free` = drop creator ref. JIT return thunks write
  `chunk->jit_advance` *after* `jit_helper_return` — the popped frame's
  chunk ref is dropped in vm_run's `-1` sentinel handlers, never in the
  helpers.
- **Env refcounts are honest and the cycle collector depends on it**:
  every owner of an `Env` — frame/creator, closure (`make_fn`), child env
  (`parent` is an owned edge), parked `chunk->env_cache` — holds a counted
  ref via `env_incref`/`env_decref`. Never stash a bare `Env*` that
  outlives its creator. The collector's `GC_FOR_EACH_CHILD` walker and
  `gc_clear_node` (eigenscript.c) must move in lockstep with the ownership
  model, so both are generated from ONE table: `GC_EDGE_TABLE`
  (eigenscript.c). A new owning edge out of Value/Env/Chunk is one new row
  there, and only *counted* edges may be walked (an uncounted edge trips
  the accounting abort and collection silently stops working).
  Conservative direction: missing an edge leaks; inventing one frees live
  memory. A new `ValType` or `ASTType` is a **build error** at every switch
  that must learn about it (#737/#738: no `default:` arms on closed-enum
  switches — `-Werror=switch` enforces exhaustiveness; don't add a
  `default:` back, enumerate the no-op cases instead). The table's rows are
  selected by `_v->type == VAL_x` guards, which `-Werror=switch` cannot
  see, so `gc_value_is_node` carries that gate for it: its switch is
  exhaustive, and a value type is a node exactly when it has rows.
- **Trace gating**: `g_trace_hist` (assignment history) and
  `g_trace_obs_hist` (observer snapshots) are compiler-set flags —
  recording is off unless the program contains a temporal query
  (`prev of`, `at`, `state_at`) or `EIGS_TRACE` is set. Don't add always-on
  per-assign work; it cost ~1/3 of dispatch-heavy runtime once before.
- **No big by-value arrays/structs in recursive functions.** The C stack is
  a resource axis no hosted gate bounds (8 MiB + guard page hides it); the
  `Compiler`'s inline `Local[512]` cost ~12.7 KiB of stack per AST level for
  23 versions until EigenOS's 64 KiB boot stack exposed it as a
  layout-sensitive heisenbug (PR #361). Audit with `gcc -fstack-usage`
  (≥ ~2 KiB in a recursive path is suspect); `tools/embed_stack_soak.sh`
  (CI) is the regression gate and also the only multi-eval-per-EigsState
  coverage in the repo.
- The Makefile `asan` target compiles with `EIGENSCRIPT_EXT_HTTP=0`; if you
  touch `ext_http.c`, compile-check with `make http` — and **sanitize** it with
  `make asan-http` (ext_http + model under ASan/UBSan; CI runs the suite that
  way, and the HTTP sections are probe-gated so they pull in automatically).
  Same for `ext_gfx.c` — in **no** default build; compile-check with
  `make gfx`. Variants coexist in per-variant `build/<variant>/` objdirs
  (#740); `src/eigenscript` is a hard link to the last-built one, so a
  rebuild no longer destroys another variant's binary — but running any
  `make` variant target mid-suite still re-points the alias under the
  suite (the #681 guard catches it).
- **A per-request leak in `ext_http.c` will not be caught by any sanitizer
  gate.** LeakSanitizer runs atexit, and the server is torn down with `kill`
  against no SIGTERM handler, so LSan never runs in the server process —
  `make asan-http` catches UAF/overflow/UB (those report at the moment of the
  bug) but not leaks. The gate for this class is
  `tests/test_http_rss_growth.sh` (suite [45c]): RSS growth between two
  **steady-state** checkpoints, never baseline-to-end (the first requests carry
  ~1.4 MB of one-time arena warmup, ~18x the real rate). Add a check there when
  you add a request path that allocates. It **skips on sanitizer builds** by
  design — ASan's redzones/quarantine grow RSS 567 B/req on a leak-free binary.
- **A builtin's failure signal is a VALUE, not a C NULL — check the type, not
  the pointer.** `make_null()` returns a perfectly good `Value*` whose `type` is
  `VAL_NULL`, so `if (!callee_result)` is true on no path most builtins can
  take. Bought (#1006): `store_update` was fixed to detect a failed
  `store_put` with `if (!put_result)`, which is vacuous — `store_put` signals
  every failure with `make_null()` and success with `make_str(key)`. The fix
  shipped in that state until a repro printed the answer; the correct test is
  `!put_result || put_result->type != VAL_STR`. When you consume another
  builtin's return **as a C function call** (not through the VM), read its
  success value and test for THAT.
- **A raise does not unwind a direct C call.** `rt_error` sets a latch that
  `CHECK_ERROR` acts on at the next VM dispatch, so a builtin calling another
  builtin directly keeps running past the raise. That is why the callee's
  return value is the only signal available at such a call site, and why
  dropping it silently loses the error (#1006: `store_update` deleted the
  record, `store_put` refused to re-insert it, and the caller was told 1).

- **`eigs_json_encode` borrows its argument and `eigs_json_parse_value` returns
  an owned ref.** `eigs_json_encode(make_num(x))` leaks the `make_num`; a parsed
  Value must be decref'd on *every* path including early returns, and the value
  read out of it before the decref. Three of the five call sites in
  `ext_http.c` had this wrong (#731) — if you touch one, re-audit the rest.

- **A shared utility that gains a VM-state-dependent call crashes every non-VM
  entry point.** `sandbox_charge` reads `g_sandbox_active` =
  `eigs_current->sandbox_active`; routing it through the general
  `strbuf_reserve`/`text_builder`/`make_list` growth chokepoints (the #963
  sandbox-budget charge) NULL-dereferenced on the `--fmt`/`--lint`/`--api`
  paths and the lexer, which run with `eigs_current == NULL` — an 8/8
  reproducible SIGSEGV in the formatter (2026-08-18). When you add a call that
  assumes an initialised `EigsState` to a utility used outside `vm_execute`,
  guard it with the codebase's `if (!eigs_current) return ...;` pattern.
  **ASan hid it**: its differently-initialised state left `eigs_current`
  non-NULL, so the ASan CI lane stayed green while the release lanes crashed —
  a green sanitizer lane is not proof the release binary is safe. And the crash
  presented in CI as a GitHub "hosted runner lost communication (CPU/Memory)"
  annotation — that was apport's core-dump handler stalling the runner, NOT
  infra; the suite section that runs `eigenscript --fmt` ([80]) is the gate.
- **Shared flags read at safepoints use the load-macro atomics idiom — and new
  flags of that shape must too.** `g_obs_needed`/`g_obs_history_gap`/
  `g_obs_exec_started` (eigenscript.h) and `g_trace_hist`/`g_trace_obs_hist`
  (trace.h) are relaxed `__atomic_load_n` MACROS over renamed `_storage`
  variables; writes go through `obs_flag_store`/`trace_flag_store` (RELEASE on
  the obs pair — the load_file guard's ACQUIRE read pairs with the
  gap-then-needed store order). The macro-as-load trick is load-bearing: an
  assignment through the old name FAILS TO COMPILE, so write sites stay
  enumerable by the compiler — that is how the JIT's baked `&g_trace_hist`
  (emitted code takes the flag's ADDRESS) was found, and it now takes
  `&g_trace_hist_storage` explicitly. Bought across #1034 rounds 16-18
  (2026-08-23): the same plain read-then-write race was found on three
  adjacent field groups in three rounds — a worker's `sandbox_run` stores
  while every thread reads at safepoints, and no happens-before edge exists
  between two workers — before a one-pass induction over every
  safepoint-read field closed the class. If you add a flag that safepoints
  read and any worker-reachable path writes, use this idiom from the start,
  and extend the round-18 induction table rather than discovering it one
  TSan report at a time. Known still-unfixed members of the class are
  ledgered on #1035/#1036 (threshold doubles — TORN reads possible; tape
  dedup statics; g_no_yield_depth).

- **A sealed ROOT env (parent NULL) takes `g_module_env_lock` on every
  `env_set_local` once the process is multithreaded, and the lock is not
  recursive.** Wrapping a walk of `g_global_env` in `env_global_shared_lock`
  and binding into the sandbox env INSIDE that region deadlocked at 0% CPU
  (#1035, 2026-09-02): the sandbox env is a sealed root, so the bind re-took
  the same mutex. Snapshot under the lock, mutate outside it; before adding
  a lock around existing code, list every callee in the region that can
  reach `env_shared_lock` -- root envs are where it hides.
