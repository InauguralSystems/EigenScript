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

## Current state: 0.15.3 released; next up

0.15.3 is a two-fix patch: the observer `improving`/`diverging`
predicates now switch at `dh_small` (matching `report` and `stable`)
instead of `dh_zero`, so in the gray band the predicate family is
mutually exclusive and agrees with `report` (#187); and `\r` is now
a string-literal escape for ASCII CR (0x0D) in both regular and
f-strings (the lexer previously dropped the backslash and kept the
literal `'r'`). Both are documented behavior changes — see CHANGELOG
[0.15.3]. Real on-disk CRLF was always handled correctly by the C
scanners; the `\r` gap only bit anyone constructing CRLF test data
inline (which is exactly how a false "scanner bug" diagnosis ended
up in EigenMiniSat's GAPS log; retracted upstream).

0.15.2 re-enables the macOS Intel JIT — the 0.14.2 holding pattern
(`EIGENSCRIPT_JIT_FORCE_OFF=1` on Darwin x86_64) is gone. The fix is
detailed below ("macos-x86_64 JIT is live"); user-visible delta is
that the macos-x86_64 release binary now ships with the JIT live
(≈3–5× on hot loops vs. interpreter-only), and macos-15-intel is now
in the CI build-and-test matrix. macOS arm64 stays interpreter-only
until the ARM64 JIT exists.

0.15.1 is the HTTP-extension rollup on top of 0.15.0's multi-state
refactor: per-worker `EigsState` for `code` routes (so route source
evaluates in a fresh worker state per request, isolated from startup
globals and from other in-flight requests), plus a cross-worker
shared-store primitive (`shared_set/get/has/delete/keys/size/clear/incr`)
that lets routes hand state across worker boundaries via JSON-as-
storage on a mutex-guarded map. The store is bounded by
`EIGS_HTTP_SHARED_MAX_BYTES` (default 64 MiB) with predictable refusal
on over-cap writes; `shared_incr` is a single-lock atomic RMW for
counters. `http_route_authed` resolves its auth source from
`shared_get("require_auth")` first (re-evaluated per request), with
the legacy in-env `require_auth` function as a back-compat fallback.
HTTP-suite coverage is 28/28 (HS14–HS26 cover the new surface);
release 1855/1855, ASan 1922/1922.

0.15.0 ships the multi-state refactor + embedding API
(`src/eigs_embed.h` — see [docs/EMBEDDING.md](docs/EMBEDDING.md)).
The runtime now supports multiple `EigsState` instances concurrently
in the same process; a C/C++ host can open, eval, set/get globals,
construct ref-counted values, and register host functions callable
from script. Phases 1–9 lifted every `__thread` global onto EigsState
(per-interpreter) or EigsThread (per-OS-thread); Phase 10 is the
opaque public API wrapping them.

0.14.2 was the first published 0.14-line release — v0.14.0 and v0.14.1
tags exist but never produced artifacts (macos-x86_64 release leg
failed twice; the 0.14.1 `MAP_JIT` patch was necessary but not
sufficient). The root cause was that the JIT prologue inlined Linux
ELF `mov %fs:tpoff, %rbx` for TLS, which has no Mach-O equivalent.
0.14.2 shipped macos-x86_64 interpreter-only as a holding pattern.

**2026-06-15 (v0.15.2): macos-x86_64 JIT is live.**
Prologue split by platform: Darwin calls a C helper
`eigs_jit_load_eigs_current()` (vm.c — the compiler emits the TLV
sequence), Linux keeps the inline `%fs:tpoff` read. Mid-thunk reads of
`eigs_current` use a new `VM->owner` back-pointer + `off_vm_owner` in
EigsJitLayout, so the body has no `#ifdef`. The dict-cache inline
probe still routes to the slow-path helper on Darwin (layout publishes
`dcache_ways=0`, trips the existing `dcache_ways == 2` guard).
`EIGENSCRIPT_JIT_FORCE_OFF` kill switch remains in jit.c for bisection
but is no longer set on Darwin. CI now covers macos-15-intel in the
build-and-test matrix; `[82]` thunk-gate enforces there too. macOS
arm64 stays interpreter-only — the ARM64 JIT is unbuilt. 0.14.0 is the rollup
(CHANGELOG.md [0.14.0] is the full record). It rolls up
the closure-cycle collector, the package ecosystem Phase 0–2 (`--pkg`
tool + `eigs_modules/` resolver + sibling repos), runtime perf wins
(OP_LINE dedup, single-alloc strcat, ITER_NEXT buffer fast path),
macOS x86_64 + arm64 distribution, the stability contract, and a
trust/identity stack: OpenSSF Best Practices passing badge, CodeQL
workflow, Scorecard 7.5/10, Sigstore signed releases (first release
to ship attestations), OSS-Fuzz PR awaiting review. 0.13.0 highlights
remain in scope on top of the language-features run (destructuring,
slicing, negative indexing, default params, streaming subprocess I/O,
recv_timeout, multi-arg spawn) and the twelve post-merge fixes
(#148–#159):

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
- **Embedding API + multi-state refactor (0.15.0)**:
  `src/eigs_embed.h` is the public C surface for embedding the
  runtime — lifecycle (`eigs_open`/`eigs_close` or finer-grained
  `eigs_state_new`/`eigs_thread_attach`/`eigs_state_init_runtime`),
  source eval (`eigs_eval_string`/`eigs_eval_file`, both REPL-style
  so top-level names accumulate in the global env), error retrieval
  (`eigs_last_error_message`/`eigs_has_error`/`eigs_clear_error`),
  ref-counted `EigsValue` handles with num/string/list/dict
  constructors and FFI registration (`eigs_register_function` uses
  the existing `BuiltinFn` shape — single `EigsValue*` arg, `VAL_LIST`
  for multi-arg calls). Smoke test: `make embed-smoke` (links the
  runtime minus `main.c` the same way `make lsp`/`make fuzz` do).
  Phase 10 of the multi-state refactor; Phases 1–9 lifted every
  `__thread` global onto `EigsState` (per-interpreter: global env,
  JIT cache, module cache, observer thresholds, handle table,
  multithread flag) or `EigsThread` (per-OS-thread: arena, error
  state, VM, JIT chunk registry, freelists/interns, recursion-depth
  guards, cycle-collector registry). Hot fields keep
  single-indirection cost via `eigs_current->field` bridge macros, so
  internal TUs still write `g_arena`, `g_has_error`, etc. — the
  embedding header is the only place that sees the opaque API. Two
  interpreters can now run concurrently in the same process; the
  internal handle/log of attached threads lives on the state.

Suite: ~1855 checks; must pass release **and** ASan with
detect_leaks=1 (the leak tally — currently 13, spawn-thread programs +
pre-existing non-closure shapes — is the gate; a jump means a new
leak, and section [87] must stay strictly leak-clean).

Open items, in rough priority (current goal: be a *good MIT-licensed
language* — the legal/hygiene side is done; the gaps are distribution,
portability, and the ecosystem story):

1. **Distribution** — macOS binaries (macos-15-intel x86_64,
   macos-latest arm64; arm64 is interpreter-only until the ARM64 JIT
   exists) and a CHECKSUMS file ship from v0.13.0; v0.14.0 additionally
   signs every binary with Sigstore build provenance
   (`actions/attest-build-provenance` in release.yml, bundle uploaded
   as `attestation.sigstore.json`; verify with `gh attestation verify
   eigenscript-<label> --repo InauguralSystems/EigenScript`).
   **Homebrew tap** lives at github.com/InauguralSystems/homebrew-eigenscript —
   tracks the latest release tag (v0.15.2 as of 2026-06-15). The old
   `inreplace` workaround for the GNU-ld-only `-z relro`/`-z now`
   LDFLAGS was dropped at v0.14.2 (Makefile gates them on Linux now,
   so the formula stays clean). Follow-ons: Docker image, AUR,
   asdf/mise plugin.
2. **Package/dependency story** — **Phase 0–2 landed in v0.14.0**:
   import cache + per-file resolution base + `eigs_modules/<name>/<name>.eigs`
   resolver (Phase 0), `--pkg` tool with `add`/`install`/`verify`/`update`
   subcommands and `eigs.json` + `eigs.lock.json` manifest/lockfile
   (Phase 1a–c), plus sibling repos InauguralSystems/eigs-package-template
   and InauguralSystems/awesome-eigenscript and a CONTRIBUTING
   "Publishing a Package" section (Phase 2). Next phases (not yet
   designed): semver resolution / version ranges, registry/discovery
   beyond the awesome-list, transitive dep handling beyond the current
   flat `eigs_modules/`.
3. ~~Stability contract~~ — done: README "Stability" section (spec =
   the surface; patch never breaks documented behavior, minor may
   with a CHANGELOG entry; everything off-spec explicitly unstable).
4. ~~`make lsp` fails on macOS~~ — root cause fixed (GNU-ld-only
   `-z relro`/`-z now` now Linux-gated in the Makefile) and the macOS
   CI leg compile-checks the LSP.
5. **Windows port** (runtime is POSIX-only) and **ARM64 JIT** (Apple
   Silicon runs interpreter-only) — the two real porting projects.
6. **Trust/identity follow-ons**: OSS-Fuzz enrollment — PR
   google/oss-fuzz#15720 submitted 2026-06-13 from the
   InauguralSystems org fork, CLA signed, all checks green except
   trial-build (NEUTRAL, non-blocking); awaiting human maintainer
   review. OpenSSF Best Practices passing badge (project 13187, 100%
   — https://www.bestpractices.dev/projects/13187); silver 13%, gold
   22%, gaps are governance/DCO/vuln-response process families.
   OpenSSF Scorecard 7.5/10 (`.github/workflows/scorecard.yml`),
   10/10 on twelve checks; remaining gaps are Code-Review
   (structurally solo), Branch-Protection (would block direct push),
   Signed-Releases (lifts to 10/10 once a v0.14.0+ release is in the
   last-5 release window). CodeQL static analysis at
   `.github/workflows/codeql.yml`. Signed releases via Sigstore now
   live (see Distribution item). Remaining trust/identity item:
   upstream a Linguist grammar
   (editors/vscode has the TextMate grammar ready; Linguist has
   usage-volume requirements, so this waits on adoption —
   `.gitattributes` maps `.eigs` to Python as the stopgap).
   **Browser playground**: `web/build.sh` (emcc) produces
   `web/dist/eigs.{js,wasm}` for an interpreter-only WASM module
   driven by `web/{index.html,app.js,style.css}`; JIT is arch-gated
   in `src/jit.c` (`__x86_64__`) so wasm32 compiles cleanly. Needs
   `-sSTACK_SIZE=4194304` (default 64KB overflows the C compiler's
   recursive `compile_node` on nested defines) and
   `-sERROR_ON_UNDEFINED_SYMBOLS=0` (emcc 3.1.74 refuses to link
   `pipe()` refs from builtins.c's `exec_capture`/`proc_spawn` under
   `-sNO_FILESYSTEM=1`; playground never calls them). Live at
   https://inauguralsystems.github.io/EigenScript/playground/ via the
   Docs site Pages workflow, which now sets up emsdk, runs the build,
   and `sudo`-stages `web/dist` into `_site/playground` (Jekyll's
   container writes `_site` under a different UID).
- Perf carryover from 0.12.0 (ROADMAP.md): NaN-boxing for *container*
  storage, extending GET_LOCAL/SET_LOCAL to all locals, per-call env
  churn. Re-profile before picking: every stage last cycle moved the
  profile shape.
