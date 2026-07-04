# Roadmap

Current version: **0.26.0**

Recently shipped (0.25.0/0.26.0, 2026-07-04): the hex contract (integer-only,
lexed on every profile, decisive `0x` prefix — #378/#381), the async abort
seam (`eigs_set_abort_flag`, #379), `bit_*` builtins aligned with the infix
int64 operators (#382), and seven new stdlib surfaces (checksum, datetime
civil math, bcd, wait_until, hexdump, harness, observer_slots — #384). Full
per-version detail lives in [CHANGELOG.md](CHANGELOG.md) — this file is
forward-looking.

## Next

The plan below is sequenced by the 2026-07 language-strategy survey
(tracking issue [#419](https://github.com/InauguralSystems/EigenScript/issues/419):
8 top-language profiles → repo ground-truth → 7 dimension gap analyses →
adversarial critic). Governing principle: **never trade the runtime
guarantee for generality — generalize at the DX surface, and route every
new capability through the trace tape so becoming more general deepens the
observer/deterministic-replay niche instead of diluting it.**

### Now (days-class, independently shippable)

- [ ] REPL line editing/history — port the EigenOS editor;
      kill the `^[[A` first-run failure ([#392](https://github.com/InauguralSystems/EigenScript/issues/392))
- [ ] Stdlib discoverability CI gate — undocumented `regex_*` are the
      proven failure mode ([#393](https://github.com/InauguralSystems/EigenScript/issues/393))
- [ ] `--test --trace-on-fail` — every failing test prints its
      `EIGS_REPLAY` invocation ([#394](https://github.com/InauguralSystems/EigenScript/issues/394))
- [x] `lib/contract.eigs` trajectory contracts — the answer to "what
      replaces static types here" ([#395](https://github.com/InauguralSystems/EigenScript/issues/395))
- [ ] Lint fences for the two load-bearing traps — W015
      outer-mutation-without-`local`, W016 bare-predicate aliasing
      ([#396](https://github.com/InauguralSystems/EigenScript/issues/396))
- [ ] `make lib` + two-file amalgamation — Lua-grade time-to-embedded
      ([#397](https://github.com/InauguralSystems/EigenScript/issues/397))
- [ ] `bench/` replay-pinned perf harness, CI-gated, published as
      docs/PERFORMANCE.md ([#398](https://github.com/InauguralSystems/EigenScript/issues/398))
- [ ] `--lint` severity control ([#399](https://github.com/InauguralSystems/EigenScript/issues/399));
      install.sh builds eigenlsp + one canonical VS Code tree
      ([#400](https://github.com/InauguralSystems/EigenScript/issues/400))
- [ ] docs/CONCURRENCY.md executable memory-model contract + TSan CI job
      ([#401](https://github.com/InauguralSystems/EigenScript/issues/401))
- [ ] COMPARISON.md convergence loops — observer semantics as boilerplate
      deletion ([#402](https://github.com/InauguralSystems/EigenScript/issues/402));
      AI-legibility single-file reference + validation ladder
      ([#403](https://github.com/InauguralSystems/EigenScript/issues/403))

### Next (weeks-class, dependency-ordered)

- [ ] Scope-aware name-resolution lint (E-class, shared with the LSP) —
      the highest correctness yield per week available
      ([#404](https://github.com/InauguralSystems/EigenScript/issues/404))
- [ ] **Language change:** bare literal list after `of` is always an
      argument list — kill the 1-element spread trap while pre-1.0 makes
      it cheap ([#405](https://github.com/InauguralSystems/EigenScript/issues/405), closes #153)
- [ ] Structured runtime errors `{kind, message, line}` with a closed
      kind set ([#406](https://github.com/InauguralSystems/EigenScript/issues/406))
- [ ] Column tracking + caret/span diagnostics
      ([#407](https://github.com/InauguralSystems/EigenScript/issues/407))
- [ ] **Trace-tape format versioning decision** — blocks anything that
      ships a tape across a version boundary
      ([#411](https://github.com/InauguralSystems/EigenScript/issues/411))
- [ ] **Deterministic cooperative task layer on the tape** — the
      strategic headline: byte-identical replay of concurrent programs,
      closing the #148 contradiction; JIT stays on (no #297 flip);
      forcing functions EigenOS + liferaft
      ([#408](https://github.com/InauguralSystems/EigenScript/issues/408))
- [ ] `lib/supervise.eigs` observer-native supervision — predictive
      (catches the silently-wedged worker), not crash-reactive; after
      #408 only ([#409](https://github.com/InauguralSystems/EigenScript/issues/409))
- [ ] Observer surface coherence — implement-or-remove `how`, decide
      `|x|=1.0`, fold in #383
      ([#412](https://github.com/InauguralSystems/EigenScript/issues/412))
- [ ] JIT back-edge abort poll — hard timeouts without `EIGS_JIT_OFF`
      ([#410](https://github.com/InauguralSystems/EigenScript/issues/410))
- [ ] eigsdap v1 as a CLI tape-stepper; DAP/VS Code deferred until
      locals ride the tape
      ([#418](https://github.com/InauguralSystems/EigenScript/issues/418))
- [ ] `--bundle` single-file distribution, optional attached tape =
      a self-replaying bug report
      ([#413](https://github.com/InauguralSystems/EigenScript/issues/413))
- [ ] `ext_net` raw TCP/UDP sockets as tape-recorded nondet inputs —
      record/replay networking no incumbent stdlib has
      ([#414](https://github.com/InauguralSystems/EigenScript/issues/414))

### Design decisions (cheap to decide, expensive to defer)

- [ ] Unicode/text position — likely bytes-forever + `lib/utf8.eigs`,
      made official in SPEC ([#416](https://github.com/InauguralSystems/EigenScript/issues/416))
- [ ] Numeric tower position — document the f64 + `bit_*` int64 contract
      and the 2^53 boundary; bigint/decimal only when a consumer forces
      ([#417](https://github.com/InauguralSystems/EigenScript/issues/417))

### AOT (ouroboros — the native-perf path; not the JIT)

- [ ] Close the F-OURO-23 envelope via `lib/checksum.eigs` as forcing
      function (ouroboros#64)
- [ ] `spec_audit` — replayable profile-guided specialization audit;
      observer trajectories as compiler evidence (ouroboros#65)

### Deliberately NOT doing (survey-critic vetoes — don't re-propose without new facts)

- Gradual/static type system — months buying a worse TypeScript; #404 +
  #395 are the correctness answer for this language.
- JIT grinding toward native claims (tracing tier, ARM64/Windows JIT
  port, thread-safe JIT) — native perf routes through AOT; concurrency
  gets the task tier.
- Untraced FFI — worse than none (silently breaks replay). Design is on
  record as tape-first ([#415](https://github.com/InauguralSystems/EigenScript/issues/415)),
  implementation blocked until a consumer forces it.
- Vendored crypto extension (AEAD/Ed25519) — security liability with
  zero consumers needing it.
- Package registry + version solver, `--pkg audit` behavioral lockfiles —
  the SHA-pinned vendoring model is structurally sounder at this scale.

### Performance carryover

- [ ] **NaN-boxing for container storage** — stack and env slots are
      already EigsSlot/NaN-boxed; list items and dict values are still
      `Value**`. Post-5h, the DMG-shaped `make_num` churn is gone
      (writes mutate in place); this now mainly buys allocation-free
      list/dict construction and reads for non-num or shared values.
      Big surface (every `data.list.items` / `data.dict.vals` touch
      site).
- [ ] **Extend GET_LOCAL/SET_LOCAL to all local variables**
      (closure-safe). Currently restricted; broadening unlocks JIT
      inline ICs on every local, not just function params.
- [ ] **Per-call env churn** — `env_new` / `env_free` per call is the
      likely top DMG cost post-5i for non-recyclable callsites.
      Re-profile before picking; the profile shape moved every stage
      this cycle.

### Downstream gaps feeding back

Filed by stress-test repos; promote into a numbered EigenScript item
when picked up:

- **Tidepool** (`InauguralSystems/Tidepool/GAPS.md`):
  GAP-001/002/003 audio (sweep, loop, per-channel volume),
  GAP-003 per-channel volume (needs multi-channel mixer),
  GAP-004 inner-loop function-call cost (partial mitigation via
  v0.12.0 hoist sweep).
  (GAP-001 audio_sweep was already shipped; GAP-002 finite-count
  audio_play_loop shipped 0.13.0; GAP-005 non-blocking channel
  recv and GAP-006 spawn-with-args both shipped 0.13.0. GAP-002
  infinite loop variant still open.)
- **EigenMiniSat** (`InauguralSystems/EigenMiniSat/GAPS.md`):
  open watchlist around CDCL hot-path inlining patterns.

### Ecosystem

- [~] Package manager — basic `--pkg` shipped (namespaced deps,
      lockfile, commit/tree verify, install/update/verify; see README
      and the implemented-behavior spec). Open: version
      ranges/solver, a registry/index format, package
      attestations/signatures, a dependency-audit command, and
      yank/deprecation policy.
- [ ] More STEM modules (graph theory, regression, numerical PDEs)
- [ ] **Windows support** — not a non-goal, just not yet. The wall is
      in the extensions, not the language core; planned as a ladder
      (CI is the verification instrument — development is Linux-only):
  - [x] Tier 0: WSL2 runs the Linux binary unchanged (works today;
        the immediate answer for a Windows user).
  - [ ] Tier 1 (the real target): native **headless interpreter**,
        JIT-off, built with MinGW-w64, suite green on a `windows-latest`
        CI leg. Shims needed: exe-path discovery (`readlink` →
        `GetModuleFileNameA`, `main.c`) and `exec_capture` (`execvp` →
        `CreateProcess`, `builtins.c`); pthread works under winpthreads.
        This is the 80/20 for adoption — `eigenscript foo.eigs` on
        Windows without WSL.
  - [ ] Tier 2: JIT on Windows — port the copy-and-patch templates from
        the System V AMD64 ABI to the Windows x64 ABI (different arg
        registers + shadow space). Large; low priority (the VM is
        correct without the JIT).
  - [ ] Tier 3: extensions on Windows — HTTP server (Winsock +
        `WSAStartup`) and gfx/SDL (`dlopen` → `LoadLibrary`). Per-file,
        on demand.
- [ ] WASM compilation target
- [ ] Foreign function interface for calling arbitrary C libraries
      from script (the *script → host* direction) — design settled as
      **tape-first** in [#415](https://github.com/InauguralSystems/EigenScript/issues/415)
      (every foreign call is a recorded nondet input, sqlite3 as the
      first binding, which also covers the SQLite DB-driver item);
      implementation blocked until a consumer forces it. The
      *host → script* direction is live via the embedding API; see
      [docs/EMBEDDING.md](docs/EMBEDDING.md).
- [ ] Crypto / HTTPS in-process (SHA hashes shipped 0.9.2; no AEAD, no
      TLS) — **deliberately deferred** per the 2026-07 survey critic:
      vendored crypto is a solo-maintainer security liability with zero
      consumers needing AEAD; revisit when one does.
- [ ] Raw TCP/UDP sockets — now specced as tape-recorded nondet inputs,
      liferaft as forcing function
      ([#414](https://github.com/InauguralSystems/EigenScript/issues/414))
- [ ] Additional DB drivers (MySQL, NoSQL; SQLite folds into the #415
      FFI plan)
- [ ] bigint / decimal numeric types — superseded by the numeric-tower
      design decision ([#417](https://github.com/InauguralSystems/EigenScript/issues/417)):
      document the f64 + `bit_*` int64 contract now, bigint only when a
      consumer forces it

### Long-term

- [x] Self-hosting compiler (EigenScript written in EigenScript) —
      `ouroboros` reaches the bootstrap fixed point (front-end +
      codegen self-host, byte-identical to the C VM). An AOT
      native-compiler arc (transpile-to-C, VM as byte-exact oracle)
      builds on it.
- [ ] GitHub Linguist submission (requires 2K+ .eigs files across repos)
- [ ] Public release

## Completed

Condensed highlights; see [CHANGELOG.md](CHANGELOG.md) for the full
per-version record.

### 0.19.0 (2026-06-26) — flat-buffer tensors

- [x] Shaped `VAL_BUFFER` (`buffer of [r, c]` / `reshape`); `matmul`/
      `add`/`relu` compute on the flat `double[]`, byte-identical to
      the nested-list path (3-layer MLP forward ~11×). `dot`/`norm`
      reductions with spec-unspecified summation association.

### 0.18.0 (2026-06-25)

- [x] Streaming audio-file playback (`audio_music_*`) in the gfx
      extension via lazily-`dlopen`ed SDL_mixer.

### 0.17.0 → 0.17.2 (2026-06-25)

- [x] Stdlib gap-fill (`any`/`all`/`find_index`/`partition`/`group_by`,
      string/math helpers, pure EigenScript).
- [x] `spawn` raises on OS thread-create failure instead of returning a
      dead handle (#269); OSR thunk confined to its own loop back-edge
      (#267); Linux release binary pinned to glibc 2.35 (Ubuntu 22.04).

### 0.16.0 → 0.16.3 (2026-06-18 → 06-19)

- [x] Windowed observer predicates (the #202 series): all six
      predicates read a window of the last N observations.
- [x] Leak campaign + HTTP DoS hardening + OSR perf (0.16.1);
      `load_file` now raises parse errors + stdlib keyword sweep
      (0.16.2); observer loop-halting made opt-in (0.16.3, #247).

### 0.14.0 (2026-06-13) — trust/identity

- [x] OpenSSF passing badge, CodeQL, Scorecard 7.5/10, Sigstore-signed
      releases, OSS-Fuzz enrollment in flight.

### 0.13.0 (2026-06-12) — language features

- [x] Destructuring assignment, slicing + negative indexing, default
      parameters, streaming subprocess I/O (`proc_*`), non-blocking
      channel recv, multi-arg `spawn`, finite-count `audio_play_loop`.

### 0.15.0 (2026-06-15) — multi-state refactor + embedding API

- [x] **Multi-state refactor (Phases 1–9).** Every `__thread` global in
      the runtime now lives on `EigsState` (per-interpreter: global env,
      JIT cache, module cache, observer thresholds, handle table,
      multithread flag, JIT tuning thresholds) or `EigsThread`
      (per-OS-thread: arena, error state, VM, freelists, intern table,
      recursion-depth guards, cycle-collector registry). Hot fields keep
      single-indirection cost via `eigs_current->field` bridge macros, so
      the common single-state path is unchanged. Two `EigsState`
      instances can run concurrently in the same process with no shared
      state.
- [x] **Embedding API (Phase 10).** Public C surface in
      `src/eigs_embed.h`: opaque `EigsState` / `EigsThread` / `EigsValue`
      handles, lifecycle (`eigs_open` / `eigs_close` or finer-grained
      `eigs_state_new` / `eigs_thread_attach` / `eigs_state_init_runtime`),
      REPL-style source eval (`eigs_eval_string` / `eigs_eval_file`),
      error retrieval, global env read/write, ref-counted value
      constructors/accessors, and `eigs_register_function` for exposing
      host C functions to script. Contract test in `src/embed_smoke.c`
      (`make embed-smoke`). Reference: [docs/EMBEDDING.md](docs/EMBEDDING.md).

### 0.12.0 (2026-06-10)

- [x] **JIT Stage 5 — inline the hot fast paths.** Buffer-INDEX_SET
      and GET_NAME/SET name EnvIC fast paths emit as native templates
      with helper fallback on guard failure, plus a
      (env, binding_version, slot) write cache for the per-iteration
      `__loop_iterations__` update. bench_dmg_shape 239→218 ms,
      bench_idxset 29.7→24.6 ms; isolation probes 2.8–3.4×. Spec in
      `docs/JIT_STAGE5_INLINE_IC.md`.
- [x] **JIT Stage 5d — inline dict-dot fast paths.** LOCAL_DOT_GET/SET
      cache-hit paths emit inline (baked hash, interned-key pointer
      equality, in-place num mutate); helper fallback repopulates the
      dict cache. Isolated dict-RMW loop −31% (65→45 ms).
- [x] **JIT Stage 5e — tracked-num operands in arith/compare
      templates.** ADD/SUB/MUL/DIV/MOD and all six comparisons accept
      heap/tracked VAL_NUM operands (refcount ≥ 2; rc==1 routes to
      interpreter so NUM_REUSE keeps in-place semantics). JIT
      SET_LOCAL template gained the interpreter's exact in-place
      branch (the swap path would free a Value `g_last_observer` can
      still point at). Poisoned-counter loop −26% (141→105 ms);
      bench_idxset −10% (24.6→22.2 ms).
- [x] **JIT Stage 5f/5g — native VAL_FN calls + per-loop OSR slots.**
      Chunks carry one OSR slot per hot loop header (`jit_osr[4]`) so
      a setup loop can't pin the slot away from the main loop;
      `jit_helper_call` pushes the callee frame and invokes a compiled
      callee's thunk directly, with `-2` deep-bail sentinel. Plus
      OP_DOT_SET coverage. bench_dmg_shape 212→156 ms (−27%); JIT now
      ~33% faster than EIGS_JIT_OFF on it (previously near parity).
- [x] **Stage 5h — DOT_SET immediate fast path + 2-way dict cache.**
      DOT_SET mutates exclusive untracked num fields in place; the
      dict field cache is 2-way set-associative (the DMG "pc"/"cycles"
      pair collided in the direct map). dmg 156→118 ms; interpreter
      (EIGS_JIT_OFF) 230→213 ms.
- [x] **Stage 5i — per-chunk call-env recycling.** A returned call env
      parks on its chunk (values nulled; param names/hash/version
      kept) and the next call rebinds params in place — EnvICs stay
      valid across calls. Guarded: single-threaded, non-captured,
      fully-bound params, layout-exact count. env_new on
      bench_dmg_shape: 500k → 9 per run; trivial-call probe −26%
      (147→109 ms), recursive fib −17%.
- [x] **Temporal-trace compile gate.** `g_trace_hist` /
      `g_trace_obs_hist` set only when the program uses a temporal
      query or `EIGS_TRACE` is set — no per-assign cost otherwise.

### 0.11.5 → 0.11.8

- [x] Cross-platform CI + sanitizer matrix
- [x] HTTP server hardening (threaded accept, protocol hygiene)
- [x] Execution trace tape + deterministic replay
      (`EIGS_TRACE` / `EIGS_REPLAY`)
- [x] Temporal interrogatives (`prev of`, `at`, `state_at` +
      line-floor index)
- [x] Debugger step-back
- [x] Leak-clean suite under ASan (enforced in CI)
- [x] Refcounted bytecode chunks

### 0.11.4 (2026-05-23)

- [x] Dict-key interning + pointer-equality short-circuit in dict inline cache
- [x] PGO build target (`make pgo`)
- [x] Builtin ref-protocol fix — direct-borrow scan replaces unconditional
      compensating incref at CALL/JIT-helper/OP_DISPATCH sites; stops the
      fresh-builtin-return leak (range, make_str, keys, …)

### 0.11.0 → 0.11.2

- [x] Eliminate dispatch builtin re-entry (OP_DISPATCH inlines without re-entry)
- [x] In-place numeric mutation for refcount-1 values (NUM_REUSE)
- [x] Dict field inline caching (128-entry direct-mapped, 99.99% hit rate)
- [x] Stack-top arithmetic (ARITH_FAST) + inlined JUMP_IF/POP
- [x] Superinstructions: LOCAL_DOT_GET/SET, LOCAL_IDX_GET, LOCAL_IDX_DOT_GET/SET
- [x] Bytecode bring-up complete — eval.c deleted, VM is sole engine
- [x] Hit DMG 0.5+ MHz target (1.094 MHz at 0.11.4)

### 0.10.0 (2026-05-21)

- [x] Bytecode VM — replaced AST tree-walker with compiled bytecode + computed-goto dispatch
- [x] Non-recursive function calls — no C stack recursion, 4096 frame depth
- [x] Stack-local optimization — GET_LOCAL/SET_LOCAL for function params
- [x] Observer stall detection in VM loops (OP_LOOP_STALL_CHECK)
- [x] list_truncate, list_remove_at, sort_by builtins

### 0.9.3

- [x] Computational geometry library — 60+ functions, convex hull, transforms
- [x] Lab data collection framework
- [x] 49 stdlib modules, 14 STEM
- [x] 15 STEM simulation examples

### 0.9.2

- [x] 12 STEM standard library modules
- [x] SDL2 audio extension
- [x] Code formatter and linter
- [x] Tidepool game near-parity

### 0.9.1

- [x] Language server protocol (LSP) — eigenlsp, VS Code extension
- [x] Hashing builtins — SHA-256, MD5, HMAC-SHA256

### 0.9.0

- [x] UI toolkit — 44 widgets, 3 themes, flex layout, animation
- [x] Real concurrency — spawn/thread_join/channels
- [x] EigenStore embedded database
- [x] Graphical debugger with observer-aware inspection
- [x] 817 tests

### 0.8.0

- [x] Reference counting GC, unobserved blocks, SDL2 graphics
- [x] Bitwise operations, terminal I/O, arena allocator
- [x] Fuzz testing, security hardening

### 0.7.0

- [x] Pattern matching, pipe operator, lambdas, break/continue
- [x] Regex, import system, EBNF grammar

### 0.6.0

- [x] REPL, dictionaries, closures, f-strings, try/catch, eval

### 0.5.0

- [x] Observer semantics, 121 builtins, 25 stdlib modules
- [x] HTTP, PostgreSQL, transformer extensions
