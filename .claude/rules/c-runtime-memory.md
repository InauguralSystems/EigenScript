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
  model: a new owning edge out of Value/Env/Chunk goes into both, and only
  *counted* edges may be traversed (an uncounted edge trips the accounting
  abort and collection silently stops working). Conservative direction:
  missing an edge leaks; inventing one frees live memory.
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
  `make gfx`. All variants land on `src/eigenscript`, so never rebuild one
  while a suite run against another is in flight.
- **A per-request leak in `ext_http.c` will not be caught by any sanitizer
  gate.** LeakSanitizer runs atexit, and the server is torn down with `kill`
  against no SIGTERM handler, so LSan never runs in the server process —
  `make asan-http` catches UAF/overflow/UB (those report at the moment of the
  bug) but not leaks. Verify a request path with RSS growth instead: drive N
  requests and sample `VmRSS` from `/proc/<pid>/status` in batches. Steady-state
  growth per request is the signal (#731 measures at 160 B/request this way).
