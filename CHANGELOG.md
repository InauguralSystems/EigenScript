# Changelog

All notable changes to EigenScript are documented here.

## [Unreleased]

### Added
- **gfx: proportional antialiased text via SDL2_ttf (#593).** The
  DeslanStudio side-by-side against its Qt prototype showed feature
  parity reading a decade old, and the dominant gap was the 5x7 bitmap
  monospace font. `gfx_text` now lazily dlopens `libSDL2_ttf-2.0.so.0`
  (mirroring the SDL2/SDL2_mixer pattern — no headers, no hard
  dependency) and renders `TTF_RenderUTF8_Blended` through the texture
  path when a font is available; `EIGS_GFX_FONT` overrides discovery,
  else DejaVu/Liberation/Noto Sans are probed. `TTF_Font*` cached per
  size; signature unchanged (`scale` maps to a comparable pixel size).
  **The fallback is load-bearing**: without the library or a font the
  bitmap path is byte-identical to before (CI containers may have
  neither), and a bogus `EIGS_GFX_FONT` is the deterministic off-switch
  (pinned by suite section [120]). New metrics builtins
  `gfx_text_width of [text, scale?]` / `gfx_text_height of scale?`
  return real pixel metrics under the active renderer (bitmap math in
  fallback); `lib/ui` measurement (`text_width`/`text_height`/
  `_draw_text_clipped`) routes through them when present — probed once
  with the catch-undefined pattern so headless stubs keep working — so
  buttons, labels, menus, tabs, and dialogs center and clip
  proportional text correctly. Output-only: no trace-tape records in
  either mode.

## [0.30.0] - 2026-07-13

### Added
- **gfx audio capture: `audio_capture_open` / `audio_capture_read` /
  `audio_capture_close` (#579).** The gfx extension's audio surface was
  output-only; a DAW transport (DeslanStudio F-DS-17) could never
  record a real microphone. Pull-model recording via the already
  dlopen'd SDL2: `SDL_OpenAudioDevice(iscapture=1)` in queue mode +
  `SDL_DequeueAudio` — no callback, no C→eigs re-entry, fits the
  existing polling clients. `audio_capture_read` drains new samples as
  a **buffer** (the #578 fast type) of floats in `[-1, 1]`, capped at
  2048 samples per call so each trace record stays under the 64 KiB
  budget (i.e. replayable); loop until empty to drain fully. Tape-first:
  open and read are TAKE/RECORD builtins — under `EIGS_REPLAY` no real
  device is opened or read, the recorded id and sample buffers are
  served off the tape (docs/TRACE.md). `SDL_AUDIODRIVER=dummy` provides
  a silent capture device, so the gfx-suite tests run without hardware;
  graceful `0`/`null` without SDL or a device.

### Fixed
- **gfx audio: `audio_play` / `audio_play_loop` accept `VAL_BUFFER`
  samples (#578).** `audio_convert_samples` was list-only, so handing a
  buffer — the type the language recommends for bulk samples and what a
  DAW render produces — silently returned channel `0`; consumers had to
  convert buffer→list per play (a 3-minute stereo render is ~16M
  appends + VAL_NUM allocations) just for the C side to re-walk it into
  int16. Buffers now convert directly off their C double array (same
  clamping and 64 MB cap as lists); empty buffers are rejected like
  empty lists. Gfx-suite checks cover play, play_loop, clamping, the
  queued length, and the empty-buffer rejection.

### Added
- **`read_line` builtin (#558)** — blocking line read from stdin
  (`getline(3)`): returns the next line without its trailing newline
  (`\r\n` stripped as one unit), `null` at EOF, `""` for an empty line.
  The stream-safe stdin primitive: `read_text of "/dev/stdin"` sizes
  with fseek/ftell and silently reads `""` on a pipe, so a CLI in a
  shell pipeline (`gen | eigenscript client.eigs`) had no way to
  receive lines. Tape-first: recorded/replayed like `read_bytes`
  (TAKE/RECORD — replay serves recorded lines, no live stdin read).
  Hosted-only (freestanding profile excludes it, like the other IO).
- **`is_dir` builtin (#576)** — `is_dir of path` → 1/0 via `stat(2)`,
  replacing the consumer-side `file_exists of f"{path}/."` probe.
  Trace-recorded (`TRACE_NONDET_RET`), unlike the older untraced fs
  predicates (`file_exists`, `ls`, `mkdir`, `getcwd` — flagged as a
  follow-up).

### Fixed
- **`json_decode` accepts RFC 8259 exponent notation (#557).** The
  number scanner accepted `e`/`E`/`+` but never the `-` of a negative
  exponent, so `1e-06` — emitted by Python `json.dumps`, JS
  `JSON.stringify`, serde, and by EigenScript's own `json_encode`
  (`%.15g`) for tiny/huge magnitudes — failed to parse: encode→decode
  did not round-trip. The scanner now implements the exact RFC §6
  grammar (`[minus] int [frac] [exp]`) and raises on malformed tails
  (`"1e"`, `"1e+"`, `"1."`) instead of letting `atof()` guess silently.
  Leading zeros stay accepted (old laxity, unchanged).

### Added
- **Lint W019 — statement-level interrogative discards its result
  (#583).** `why is "..."` where `why` is a question word parses as the
  interrogative *expression* form, not an assignment — as a bare
  statement it is a silent no-op (the Tidepool hit: a catch handler
  "reassigning" a `local why` silently kept the stale value). Every
  statement-level interrogative (question words and `prev of`) is dead
  code and now warns; interrogatives inside expressions
  (`print of (why is x)`) are untouched. docs/DIAGNOSTICS.md documents
  the code.

### Fixed
- **Lint W013 attributed to the shadowing `define` line (#556).** The
  parser stamped `AST_FUNC` nodes with the line of the first statement
  *after* the body, so W013 pointed at innocent code, the documented
  same-line `# lint: allow W013` never matched, and consecutive
  shadowing defines chain-suppressed each other (N shadows → only the
  last warned). The node now carries the `define` token's line;
  same-line pragmas work and each shadow warns on its own line.
- **LSP no longer advertises a phantom `input` builtin (#559).**
  `eigenlsp` completion offered `input of prompt`, which was never
  registered in the runtime — accepting the completion produced
  `undefined variable: input`. Entry removed (#558 tracks a real
  stdin-read builtin).
- **`load_file` is silent by default (#560).** Every successful load
  printed an unconditional `[load_file] Loading ...` banner to stderr —
  a consumer CLI loading 17 fragments opened with 17 lines of runtime
  chatter no flag could turn off. No successful builtin announces
  itself; the banner is now opt-in via `EIGS_VERBOSE_LOAD=1`.

### Added
- **lib/ui input-event trio (#567, #568, #569)** — first-consumer
  findings from the DeslanStudio arrangement timeline:
  - **#568 — mouse events carry modifier state.** `gfx_poll` now
    attaches `shift`/`ctrl`/`alt` (0/1) to `mousemove`, `mousedown`,
    `mouseup`, and `wheel` events (via `SDL_GetModState`), mirroring
    what key events already exposed. Additive dict fields — headless
    tests that synthesize event dicts are unaffected (absent keys read
    null).
  - **#567 — canvas drag/mousemove seam.** `dispatch`'s drag-in-progress
    path is now registry-driven: each built-in draggable type (slider,
    vslider, knob, scrollbar, waveform_view, splitter, color_picker)
    registers an `on_drag(w, ev)` handler, and a custom widget that
    claimed the pointer (new `claim_drag of w` / `release_drag of null`
    API) receives every drag mousemove *and the terminating mouseup*
    through its `on_mouse(w, ev)` callback — press-move-release gestures
    now complete on a canvas. Hover mousemoves are also delivered to
    `on_mouse` (branch on `ev.type`). The sharp edge is gone: a claimant
    outside the old hardcoded type list no longer falls into the slider
    updater's `type_mismatch`; a claimant with no handler is a silent
    no-op.
  - **#569 — wheel seam.** A widget under the cursor exposing
    `on_wheel(w, ev)` consumes wheel input before the `scroll_panel`
    walk (`ev.x`/`ev.y` are the scroll deltas; modifiers ride along for
    ctrl+wheel zoom). Also fixed: `_layout` now subtracts a
    `scroll_panel`'s scroll offset when caching children's `_ax`/`_ay`,
    matching render and hit-test, so a canvas inside a scrolled panel
    keeps correct mouse math.
  - `examples/ui_canvas_events.eigs` (timeline-style canvas: clip
    drag-move, rubber-band select, ctrl+click toggle, wheel pan,
    ctrl+wheel zoom-at-cursor) exercises all three seams; UI suite [63]
    extended 81 → 115 checks.

### Fixed
- **Entropy walk: cycle + shared-structure detection (#571).** The
  observer's container entropy walk (`compute_entropy`) had only a
  depth-64 cap, so back-references multiplied re-walks: one
  back-referencing dict was linear (32 re-entries), a second made every
  observed container assignment ~2^32 subtree walks (0.07 ms → seconds
  to minutes — found by the DeslanStudio 4d port, whose second
  shell-back-referencing UI view hung `shell_new` for >10 minutes).
  The walk now carries a stack-local visited set (open-addressing
  pointer table, 16 inline slots, heap spill only for larger graphs;
  containers only — scalars pay nothing, and per-computation stack
  state can't race when spawn-shared graphs are observed on two
  threads at once). **Semantics**: each container node contributes its
  entropy once per computation; a re-encountered container reads as a
  0-entropy leaf. Trees and scalars are byte-identical to before;
  DAG-shaped data is no longer double-counted; cyclic graphs are now
  well-defined (previously depth-truncation-dependent). Suite section
  gated by `test_entropy_cycles.eigs` (8 checks);
  SPEC/OBSERVER/COMPARISON updated.

### Added
- **Borrow-scan guard in sanitizer builds (#548).** The #546 cap on
  `vm_borrow_scan` rests on the invariant *"no builtin returns a
  borrowed direct child past index 7"*, which was enforced only by a
  comment. In ASan builds the scan now continues past
  `VM_BORROW_SCAN_CAP` and `abort()`s naming the offending builtin
  (env-chain reverse lookup) on a match the capped scan missed —
  converting a future missed compensating incref from a
  lifetime-dependent use-after-free heisenbug into an immediate red
  test run. Zero release-build cost (compiler-set ASan macro gate).
  Validated by a planted fault: `__borrow_guard_selftest` (registered
  only in sanitizer builds under `EIGS_BORROW_GUARD_SELFTEST`, so
  fuzzers can't reach a deliberate abort) violates the invariant on
  purpose; suite [119] proves the abort fires, names the builtin, and
  that within-cap borrows stay clean. SKIPs on release.

### Fixed
- **Dot access accepts keyword-named fields (#542).** `d.loop`, `d.in`,
  `d.when` — any word keyword now parses as a dot key (read, write,
  compound assign, any chain depth, all three parser postfix sites).
  The position after `.` admits nothing but a field name, so the old
  `TOK_IDENT`-only check rejected programs with no ambiguity to protect
  against, leaving keys creatable by literal, `dict_set`, and
  `json_decode` reachable only by bracket — and contradicted SYNTAX.md's
  soft-keyword promise for `d.prev`/`d.at`. Found porting a DAW whose
  data model has `clip.loop` / event `when` fields. Suite [118]
  (49 checks); SPEC/SYNTAX/GRAMMAR/COMPARISON updated. The ouroboros
  `frontend.eigs` mirror lands with the next `EIGS_REF` bump
  (deferred-mirror pattern, #326/#328).

### Added
- **`--bundle`: single-file distribution (#413).** `eigenscript
  --bundle app.eigs out [--with-tape tape]` copies the runtime binary
  and appends an archive — the script, the adjacent `eigs_modules/`
  tree, the stdlib `lib/` modules, and optionally a trace tape — into
  one executable that runs on a machine with no EigenScript checkout.
  Startup detects the trailer magic on the binary's own tail, extracts
  to a tempdir (removed at exit), and rewrites argv to run the
  extracted script, so every existing resolution rule just works with
  no VFS or resolver changes. With a tape attached, `out --replay` is
  an **executable bug report**: it replays byte-identically, serving
  every nondet input from the tape — and the #411 version contract is
  pinned by construction, since the bundle carries the exact binary
  that recorded the tape. In bundle mode all arguments belong to the
  script (only `--replay` is intercepted); torn archives refuse with
  exit 3; re-bundling from a bundle copies only the runtime image.
  `tests/test_bundle.sh` (suite [42g], 8 checks) covers script+modules+
  stdlib from a bare cwd, arg passthrough, byte-identical replay of the
  recorded nondet, no-tape/torn refusals, and re-bundle size stability.
  docs/BUNDLE.md documents the format and the AOT (ouroboros) tier as
  the native-speed variant of the same single-file story.

### Fixed
- **Builtin calls with a single list argument were O(len(list)) (#546).**
  The direct-borrow heuristic that runs after every builtin call scanned
  the entire argument list comparing item pointers against the result.
  For multi-arg calls that list is the small VM-packed temp, but for a
  single list argument it was the caller's own list — so `len of xs`
  cost O(len(xs)) and the idiomatic `loop while i < (len of xs):` was
  quadratic (~520x slower than a hoisted length at 88k elements;
  surfaced by DeslanStudios audio-buffer rendering). The scan is now
  factored into `vm_borrow_scan` (shared by CASE(CALL),
  jit_helper_call, and OP_DISPATCH) and capped at the maximum builtin
  arity: a borrowing builtin can only return a child it actually read,
  and every builtin reads its argument vector at small fixed indices,
  so items past the cap can never be the borrowed result. The borrow
  contract (coalesce/dict_set returning a child of a raw list variable,
  a dying-temporary argument, >cap-length raw lists) is pinned in
  tests/test_call_semantics.eigs. 88k-iteration len-in-condition loop:
  5,033ms -> 17.5ms.

### Added
- **Tape format v2: scope-qualified locals (#539 v2).** A new `S <fn>
  <depth> <serial>` scope-transition record qualifies the `A` records
  that follow, so a function-local binding and a same-named top-level
  one are separate streams — and two invocations of the same function
  never merge (`<serial>` is a per-thread frame-instance id stamped at
  every frame push, `CallFrame.call_serial`). Emitted with the L-record
  dedup discipline: byte cost lands only at call boundaries that
  actually assign (worst-case call-heavy fixture: +43% tape bytes, ~8%
  traced runtime; zero S records in straight-line module code, zero
  cost untraced). `TRACE_FORMAT_VERSION` 1→2 — v1 tapes refuse per the
  #411 version-and-reject rule; replay skips `S` like `A` (byte-exact
  replay determinism unchanged). `--step` reconstructs the call chain
  from the serials: `p` shows the live chain's bindings innermost-first
  with `{in fn}` notes and shadowing (dead frames' locals no longer
  appear), and `t name` resolves to the frame's own stream, so
  trajectory labels are per-invocation. `tests/test_step.sh` grows six
  scope checks; docs/TRACE.md documents the record and the v2 history.
- **Runtime-error carets + token-precise LSP ranges (#407 residual).**
  Uncaught runtime errors now print the same one-line source excerpt +
  `^` caret as parse errors, with the column attributed to the failing
  token (the `[` of an out-of-range subscript, the operator of a type
  mismatch, the undefined identifier, the `of` of a bad call). Mechanism:
  a per-byte `cols[]` table beside the chunk's `lines[]` (stamped by
  `compile_node`'s save/set/restore position cursor — zero dispatch-loop
  cost, no OP_LINE/tape change), a refcounted per-unit source blob shared
  by nested function chunks (so REPL lines, eval'd strings, and imported
  modules all excerpt their own source), and uncaught-error printing
  deferred from raise time to the dispatch loop's `CHECK_ERROR`, which
  knows the failing instruction's offset. A `lines[off] == error_line`
  guard suppresses the caret whenever the position can't be attributed
  confidently (e.g. JIT-advanced ip), so a caret never points at the
  wrong line. The `Error line N:` message and `  at fn (line N)` trace
  lines are byte-unchanged. LSP diagnostics are now token-precise:
  E002 (parse) and E003 (undefined name) squiggle exactly the offending
  token instead of the whole line (0..1000 span remains only as the
  no-position fallback). `examples/errors/*` pin runtime carets via a
  new `# expect-caret:` directive; `tests/test_lsp.py` pins the ranges.
- **The observer pair: value-channel raw-step signals (#422) + trajectory
  snapshots across call boundaries (#421).**
  - *#422*: relative normalization (`Δv/(1+|v|)`) erased exactly two
    trajectory classes, and both misread as *accepting* regimes: an
    additive/polynomial runaway (`x → x + c` seeded large) read
    `converged`/`stable`, and a perpetual oscillation below the deadband
    (`x → -x` seeded at 4e-4, or a fixed absolute swing around a large
    offset) read `stable`/`converged`. The `ObserverSlot` value channel now
    keeps a parallel window of RAW steps and asks one structural question —
    are the steps **non-vanishing** (recent-half mean ≥ half the older-half
    mean, above a `4·ε·(1+|v|)` fp-noise floor)? Non-vanishing same-sign
    steps classify `diverging` (the value channel's first use of the label;
    geometric runaway upgrades from `moving` too); non-vanishing alternating
    steps classify `oscillating`. Damped (decaying-step) trajectories still
    settle to `converged`. `lib/contract.eigs`: `expect_converging` now
    fails FAST on a mid-run `diverging`; `invariant_stable` throws on it;
    the documented #422 blind-spot caveats are gone.
  - *#421*: observer state is binding-identity, so a value passed into a
    function arrived with no history — a contract could not classify what
    its caller built. New special form `trajectory of x` snapshots the
    binding's observer windows into a plain transparent dict
    (`kind`/`rel`/`raw`/`dh`/`entropy`/…), and new builtin `classify of t`
    (or `classify of [t, "entropy"]`) classifies it with the SAME
    slot machinery `report_value`/`report` use (opcodes
    OP_TRAJECTORY_SLOT/NAME, appended per the ABI rule). `classify` of a
    non-snapshot raises `type_mismatch` — a bare value never silently
    classifies as "no trajectory". `lib/contract.eigs` gains the snapshot
    form `expect_regime of [trajectory of x, expected, msg]` alongside the
    step-fn contracts; the lint knows `trajectory` as a special form (E003).
  - Suite section [50j2] (`tests/test_trajectory.eigs`, 20 checks) pins both
    issue repros red→green, the damped/settled/halving no-regressions, the
    call-boundary crossing, both channels, the loud error paths, and
    `expect_regime`. SPEC.md/COMPARISON.md gain byte-pinned examples;
    OBSERVER.md documents the raw-step signal and the snapshot model.
- **`--step` — the eigsdap v1 CLI tape-stepper (#418).**
  `eigenscript --step <tape> [source.eigs]` opens a recorded trace tape
  (from `--trace`, `EIGS_TRACE`, or a `--test --trace-on-fail` failure) in
  an interactive time-travel debugger: step forward AND backward over line
  events, breakpoints as line filters with `c`/`rc` continue in both
  directions, jump-to-line both ways, and binding reconstruction from the
  tape's assignment deltas at any position. `p` shows each binding's value
  *plus its observer-trajectory label* — computed by the runtime's own
  #294 value-channel classifier (`observer_slot_record_value` is now
  exported so the stepper feeds reconstructed histories through the same
  `ObserverSlot` the language uses; a mirror implementation could drift,
  this cannot) — and `t <name>` shows the running label per assignment, so
  stepping back rewinds the *diagnosis*: walk `rc` backward to the exact
  step where a binding flipped from `[moving]` to `[oscillating]`. Pure
  tape reader (nothing executes, step-back is an index decrement); #411
  version rule enforced exactly like replay (mismatch = refuse, exit 3);
  CLI-only translation unit (`src/step.c`), excluded from the embed/LSP/
  freestanding profiles. New suite section [42f] (16 checks,
  `tests/test_step.sh`) covers stepping, label flips on back-step,
  breakpoints, jumps, refusals, and driving a `--trace-on-fail` tape.
  Ships with docs/DEBUGGING.md — the failure→replay→interrogate loop,
  the stepper, and the temporal interrogatives in one place.

## [0.29.0] - 2026-07-10

### Added
- **`task_detach` — fire-and-forget tasks reap their handle slot (#530).**
  Finished tasks were never removed from the 255-slot handle table before
  process exit, so `task_spawn` failed after 255 spawns per process — a
  LIFETIME cap, even when every task was joined. `task_detach of id`
  (pthread-detach precedent) marks a task nobody will join: it is reaped the
  moment it finishes (or immediately if already finished, or when
  `task_kill`ed), returning its slot to the pool — the cap now bounds
  *concurrent* tasks, as its message always claimed. A detached task's
  uncaught death still prints and still fails the process (#493 — the flag
  survives the reap in a scheduler-level counter). A task may detach itself
  via `task_self`. Also fixes ready-queue poisoning found by the same
  workload: a task killed while READY left a stale queue entry, and enough
  of them filled the fixed 256-slot queue, whose push then SILENTLY dropped
  real wakeups — a spurious "deadlock". `task_kill` now removes the victim's
  pending entry. Surfaced by the #523 liferaft migration (a deliverer task
  per in-flight message; crash-teardown kills pending deliverers in bulk).
- **`task_self` — a task can learn its own id (#526).** `task_self of null`
  returns the running task's id in the same integer space `task_spawn`
  returns (the main task is 0, including before any task has been spawned).
  Surfaced by `lib/supervise` (#409): without it a worker has no reply
  address to hand out, so message-link supervision — a worker delivering its
  exit as an ordinary message to its supervisor's mailbox — was not
  expressible. Deterministic (pure scheduler state, zero tape records).
- **`lib/supervise` — observer-native supervision (#409).** A supervisor over
  the #408 cooperative task layer that, beyond BEAM-style crash-restart, also
  catches the silently **wedged** worker — alive, not crashed, never timing
  out, but no longer making progress — a signal BEAM structurally cannot see.
  Workers publish raw progress with `heartbeat of [slot, value]`; the
  supervisor samples each alive worker every tick, feeds a **bounded** signature
  (`1.5 + v % 8`, dodging the #294 flat-entropy blind spot) into that slot's
  observer trajectory, and restarts a worker whose signature has gone `stable`
  after a warm-up window (the EigenOS red-title pattern, generalized) or that
  died with an uncaught raise — each up to a per-worker restart-intensity cap.
  `supervisor_new`, `supervise of [sup, fn, slot]`, `supervise_step`, and
  `supervise_run of [sup, max_ticks]`. Deterministic by construction; flagship
  `examples/supervisor_tree.eigs`. Surfaced a gap: a task cannot learn its own
  id (no `task_self`), so the message-link supervision variant is not yet
  expressible — filed separately.
- **Lint `W018` — `e.kind` compared against an out-of-set error kind (#469).**
  A `catch` handler comparing a caught error's `.kind` against a string that is
  a near-miss of a real kind — a case variant (`"IO"`), a single-character typo
  (`"index_rage"`), or a kind renamed out from under the handler — is dead code
  that silently never fires. The new rule warns and suggests the intended kind.
  Zero-false-positive by construction: the closed kind set is derived from
  `err_kind_name` at run time (no hand list to drift — it already covers the
  post-#509 `deadlock`), and a warning requires all of (1) the `.kind` read off
  a **catch-bound** variable, (2) a non-exact match, and (3) a near-miss
  (case variant or edit distance 1) — so a valid kind and a genuinely custom
  `throw {kind: "..."}` value both stay silent. Calibrated to zero hits over
  `lib/`, the test corpus, and the consumer repos.
- **Per-file lint allow-list in `eigs.json` (#455).** A project can now silence
  a lint code for a whole file without editing it — an `eigs.json` `lint.allow`
  map from project-root-relative path to a list of codes (`"all"` silences
  every code): `{"lint":{"allow":{"lib/generated.eigs":["W003","W017"]}}}`. The
  escape for generated or vendored modules that shouldn't carry inline
  `# lint: allow` comments. Resolution walks from the linted file up to the
  project root (the dir containing `eigs.json`, reusing the module resolver's
  walk), so it applies regardless of the cwd. A code allowed here filters
  exactly like a `# lint: allow-file <code>`. Closes the last residual of #399.
  (`--lint`; the in-file directives still cover the LSP.)
- **`lib/sync` — cooperative-task locks (#488).** A `lib/sync.eigs` stdlib
  module giving mutual exclusion **across** `task_yield` points for the #408
  task layer: `lock_new` / `lock_acquire` / `lock_release`, plus
  `with_lock of [lock, fn]` (runs `fn of null` under the lock, releasing even
  if the body raises, then re-raising). `lock_acquire` cooperatively yields
  until the lock is free, then claims it — correct because there is no
  preemption between the acquire check passing and the claim. Surfaced by the
  `eddy` consumer (concurrency-control DST): a critical section that spans a
  yield needs an explicit lock, since only a non-yielding region is implicitly
  atomic.
- **`must_not_yield of fn` — assert a critical region is atomic (#488).** The
  other half of #488: a region relies on cooperative atomicity (mutual
  exclusion for free) *only* while it issues no yield, but nothing marked such
  a region, so a `task_yield` — or a builtin that yields internally — introduced
  later broke atomicity **silently** (a rare, seed-dependent anomaly).
  `must_not_yield of fn` runs `fn of null` as an atomic section: any suspending
  task builtin inside (`task_yield`, a blocking `task_recv`/`task_join`,
  `task_sleep`) raises `value` instead of suspending, so the mistake fails
  loudly. Non-suspending ops (`task_try_recv`, `task_send`, joining a finished
  task) are allowed. The region depth is balanced even when the body raises,
  and it nests. Surfaced by the `eddy` consumer's snapshot-isolation commit
  loop (atomic only because it contains no yield).

### Changed
- **`deadlock` is now catchable (#509).** A cooperative-task deadlock (all
  tasks blocked, none runnable) was raised inside the scheduler trampoline and
  surfaced as a fatal process error — a `try`/`catch` around `task_join` never
  ran. It is now delivered as an ordinary catchable error at the **main task's**
  blocked join/recv site: the handler binds `e.kind == "deadlock"` (message
  `all tasks are blocked — deadlock`) and execution continues after the block,
  matching how a killed task's `interrupt` is catchable. A deadlock with no
  handler on main stays terminal — loud message, non-zero exit — so uncaught
  behavior is unchanged; a handler inside a *worker* does not catch it (the
  error goes to main). Implementation note: the fatal print no longer routes
  through `rt_error`'s `g_try_depth` gate, since a suspended worker's still-open
  try can leave that global non-zero between task switches (it is not part of a
  task's saved slice) — the trampoline decides catchable-vs-terminal from main's
  saved frames directly.
- **Cooperative task layer — exit-code and arena-guard fixes (#493, #510).**
  Two silent-tolerance holes in the #408 task layer:
  - **#493:** a worker that dies of an uncaught error while nothing
    `task_join`s it now makes the **process exit non-zero** instead of
    silently returning 0 — a fire-and-forget worker's death can no longer
    green a run (`task_spawn` without a join hid failures). Joining and
    catching still recovers (exit 0); a deliberate `task_kill` is a teardown,
    not an uncaught error, and does not fail the process. Documented in
    docs/SPEC.md (task layer) and the docs/DIAGNOSTICS.md exit-code table.
  - **#510:** the arena guard on the suspending task builtins
    (`task_yield` / `task_recv` / `task_sleep`) is now checked **before** the
    no-scheduler short-circuit, so `arena_mark … task_yield … arena_reset`
    raises `value` even before any `task_spawn` — the "no-op with no tasks"
    rule no longer hides the documented "forbidden inside an arena" rule.

- **#483 — leak of the suspended main slice on a fatal exit.** When the process
  ends while task 0 (main) is still **suspended** — a `deadlock`, or main
  blocked on a join/recv that never resolves — `task_sched_thread_free` freed
  main's saved-slice arrays on the "main always ran to completion, slice is
  empty" assumption, which is false here. Main's base module frame owns a
  counted chunk ref (the script chunk) and its operand stack owns value refs;
  those leaked (the script chunk plus every nested fn chunk in its constant
  pool — ~10 KB on the deadlock repro). Now the slice is torn down ref-correctly
  (mirroring `task_free`'s worker-slice teardown) before the arrays are freed.
  Worker tasks were already clean (reaped by `handle_table_drain` → `task_free`);
  only main's slice was missed. Gated by a leak-checked deadlock regression test
  — which is also what surfaced this: the original repro read clean under a
  one-shot LSan run (a stale stack slot kept the block reachable — a false
  negative), and only the in-suite test made it reproduce reliably.
- **Silent-tolerance audit, batch 2 — invalid input raises instead of
  returning a silent wrong value** (#497, #498, #499, #501, #502, #511,
  #512). Builtins that used to fold bad input to a `null`/`0`/`""`/
  wrong-order sentinel — the hardest class of bug to spot in a data or
  numeric pipeline — now raise a catchable error from the closed error-kind
  set:
  - `matmul` — incompatible shapes raise `value`, non-matrix operands raise
    `type_mismatch`, an oversized result raises `limit` (#512).
  - `sha256` / `md5` / `sha256_file` / `md5_file` / `hmac_sha256` — a
    non-string argument raises `type_mismatch` (was the empty-string
    sentinel, i.e. a silent wrong digest); the `_file` variants also raise
    `io` when the file can't be opened (#511).
  - `range` — a non-numeric argument raises `type_mismatch` (#497); a
    request past the 1M cap raises `limit` instead of silently building an
    unbounded list (the cap used to size only the prealloc while the loop
    ran to the original bound — an OOM, #498).
  - `sort_by` — a key function returning a non-number raises `type_mismatch`
    (was coerced to `0.0`, a silent wrong order); mirrors `sort` (#368) (#501).
  - `get_at` / `set_at` and `buf_get` / `buf_set` — an out-of-range index
    raises `index_range` and a non-list/non-buffer target or non-integer
    index raises `type_mismatch`, matching the `xs[i]` operator (was a silent
    fold-to-0 / no-op) (#499, #502).

  Batch 2b — the remaining builtins in the same class (#500, #503, #504,
  #506, #507, #508):
  - `len` — a value with no length (number, fn, `null`, …) raises
    `type_mismatch` instead of folding to `0`. Callers meaning "empty if
    absent" already guard with `x != null and len of x`, and `and`
    short-circuits, so the guarded `len` is never reached (#508).
  - `append` — a non-list target (including the `append of xs` #405
    arg-vector footgun, where a 2-element `xs` arrives as `[target, item]`)
    raises `type_mismatch` instead of a silent no-op. Pass a literal list
    whole with the paren form: `append of ([ys, item])` (#506).
  - `regex_match` / `regex_find` / `regex_replace` — an invalid pattern
    raises `value` (was `[]` / the input unchanged — indistinguishable from
    a clean no-match) and a non-string operand raises `type_mismatch` (#500).
  - `substr` — a negative start counts from the end, matching `char_at` and
    the `[]` operator (was a flat clamp-to-0 — an inconsistency) (#504).
  - `list_truncate` — a negative length raises `value` instead of silently
    emptying the list (an undocumented soft clamp) (#503).
  - `json_path` — an empty path segment (a leading/trailing dot or `..`)
    raises `value` instead of being silently skipped by `strtok`, which
    masked a malformed path; a genuine lookup miss still returns `""` (#507).

  Batch 2c — `json_decode` strictness (#495):
  - `json_decode` rejects malformed input with a `value` error instead of
    silently succeeding. A truncated document (`[1, 2,`, `{"a":`), an
    unterminated string, a partial/garbage container (`{]`, `[1,2,3,]`),
    over-deep nesting, and trailing garbage after a complete value
    (`[1,2,3] trailing`, `42abc`) all used to return a partial value with
    `rc=0` — and a genuine JSON `null` was indistinguishable from a parse
    failure (both returned `null`). Valid JSON is unchanged. `json_path` and
    the HTTP header/body parsers keep their lenient behavior (they ignore the
    strict-parse flag) (#495).

  Batch 2d — channel/IO/parser silent successes (#505, #490, #494):
  - `send` to a **closed** channel raises a catchable `value` error instead
    of silently dropping the value with `rc=0`. A producer that races a
    consumer's `close_channel` used to lose messages with no signal; now it
    fails loud. `recv` on a closed empty channel still returns `null`
    (EOF-like — that half is intended) (#505).
  - `load_file` of a missing/unreadable path raises a catchable `io` error
    instead of printing to stderr and returning a silent `null` with `rc=0`.
    This matches `import`'s severity and the same function's own parse/compile
    failure paths; a typo'd path is no longer a soft no-op (#490).
  - **Parser: a missing expression is a parse error, not a silent `null`.**
    An expression required after `is` / `of` / a unary operator, or as a
    `throw` / `print` argument, that runs into the end of the line
    (`x is`, `print of`, `throw of`, `eval of "x is "`) used to bind/emit
    `null` and continue with `rc=0` — a truncated or generated program looked
    like a soft no-op. It now raises `Parse error line N: expected expression`
    (catchable `parse` from `eval`/`import`/`load_file`). Bare `return`
    (the one legitimate empty-expression position) still yields `null` (#494).

### Fixed
- **Same-instant sleeper wake order no longer depends on handle IDs (#535).**
  `sched_wake_sleepers` woke due sleepers in ascending handle-id order, but
  ids come from a rotating next-fit cursor — so once slots recycle (#530),
  the tie-break encoded the process's whole allocation history and two
  identical seeded runs in one process could interleave differently
  (surfaced by liferaft's in-sweep fault verify failing to reproduce
  standalone). Tasks now carry a monotonic `spawn_seq` and same-instant
  wakes order by it — a pure function of the run. Regression-pinned with a
  wraparound-straddling sleeper race (`tests/test_task_sleep_order.eigs`).
- **JIT: task code now stays interpreted at EVERY entry point (#533).** The
  #408 ruling ("task code runs interpreted") was enforced only at the
  fresh-entry gate: the OSR back-edge counter/handoff and the OP_CALL /
  OP_DISPATCH thunk entries weren't task-gated, so a task's hot loop was
  JIT-compiled MID-TASK after ~OSR-threshold iterations — and
  `jit_helper_call` has no suspend check, so a blocking `task_recv`'s
  placeholder null flowed onward as the received message and the leaked
  suspend flag suspended the task mid-expression at a later call site.
  Symptom: mass task death / `null` from `task_recv` / corrupted locals
  after ~5000 loop iterations (first seen as liferaft's node tasks dying en
  masse under chaos — reachable at all only once #530 lifted the lifetime
  spawn cap). All four entry points now check `g_task_sched`;
  regression-pinned with an OSR-threshold-crossing recv loop
  (`tests/test_task_osr.eigs`, red pre-fix / green post-fix).
- **`dict_remove` no longer inflates the dict's hash table exponentially.**
  The re-index rebuild after a removal reused the grow path's blind
  capacity-doubling, so N removes on one dict grew its table by 2^N —
  ~25 insert/remove cycles of a single key allocated gigabytes and OOMed
  the process. The rebuild now sizes the table from the live entry count
  (identical doubling behavior on the >70%-load grow path). Surfaced by
  liferaft's per-message pending-registry churn during the #523 task-layer
  migration; regression-pinned in `tests/test_dict.eigs` (200-cycle churn).
- **`args` now rides the trace tape (#471).** The `args` builtin returned
  `argv` directly, unwrapped — the last un-taped nondeterminism source
  reachable by a pure script, and a hole in the closed-world invariant behind
  deterministic replay. A program that branched on `args` recorded a tape
  under one invocation and silently diverged when replayed under a different
  argv (the exact class chaos-mode `--seed N` scheduling for the #408 task
  layer would hit). The recorded argument list now rides the tape as one `N`
  record and replay serves it regardless of the live argv. Because `args`
  *builds* its list before returning, it uses the `TRACE_NONDET_TAKE` /
  `TRACE_NONDET_RECORD` pair (not `TRACE_NONDET_RET`), so under replay the
  live list is neither built nor leaked. Regression: `tests/test_replay.sh`
  (record under `A B`, replay under `X Y Z`, recorded args win).
- **Circular `import` / `load_file` no longer crashes (#496).** A mutual or
  self-referential `import` (a→b→a) or `load_file` used to recurse through
  `vm_execute` until the C stack overflowed — SIGSEGV, `rc=139`, uncatchable.
  The module cache is only populated *after* a load completes, so the
  re-entrant load missed the cache and recursed. A per-`EigsState` in-flight
  load stack now records paths whose load is on the current C stack; the
  loader raises a catchable `io` error (`import: circular dependency — '…' is
  already being loaded`) instead of recursing. Shared by `import` and
  `load_file`, so a cycle that crosses the two is caught too. Repeated
  *sequential* loads of the same file stay legal — only active re-entrancy is
  a cycle. Regression: suite section **[115]**.
- **`for x in xs` snapshots the iteration length at loop entry (#491).**
  ITER_NEXT used to re-read the sequence's *live* length every step, so a
  body that appended to `xs` looped forever (unbounded memory, OOM) and one
  that removed from the front skipped elements. The length is now fixed at
  entry and bounded by `min(snapshot, live length)`: appending can't extend
  the loop, and removing stops at the live length instead of reading a freed
  slot. `for` over a sequence mutated in its body is now well-defined — it
  visits exactly the indices 0..N-1 that existed at entry, read live (SPEC
  updated). Applies to both the interpreter and JIT tiers and to list
  comprehensions. Regression: suite section **[117]**.

## [0.28.0] - 2026-07-08

### Added
- **Cooperative task seeded scheduling — increment 4 (#408).**
  `task_sched_seed of n` switches the scheduler from FIFO round-robin to
  picking the next ready task from a seeded, platform-independent PRNG
  (splitmix64). The schedule stays **fully deterministic** — the same seed
  produces the same interleaving on every run and replays byte-identically
  with **zero tape `N` records** — but a *different* seed explores a
  *different* ordering. This is the pluggable strategy hook a deterministic
  simulation tester (liferaft) uses to search the interleaving space while
  keeping every run reproducible. Without a seed the scheduler is
  unchanged (the FIFO fast path is untouched), so existing programs behave
  exactly as before. Completes the #408 primitives; next is the liferaft
  differential-proof migration.
- **Cooperative task virtual time — increment 3 (#408).** `task_sleep of
  ticks` suspends a task on a **logical clock**; `task_now of null` reads
  it. The clock starts at 0 and only jumps *forward to the earliest
  sleeper* when nothing else is runnable (discrete-event simulation) —
  so a program that sleeps runs in zero real time and stays deterministic
  by construction: identical on two fresh processes, replays
  byte-identically, and records **zero tape `N` records** (the clock is
  not a nondeterministic source). Sleepers waiting on the clock are no
  longer mistaken for a `deadlock`; ties at the same wake time break by
  ascending task id. A negative sleep clamps to 0; `task_sleep of 0` is a
  same-tick yield; with no task ever spawned it is a no-op like
  `task_yield`. This is the election-timeout / heartbeat primitive the
  deterministic Raft simulator (liferaft) needs. Not yet: the pluggable
  seeded-strategy hook for the DST consumer.
- **Cooperative task mailboxes — increment 2 (#408).** `task_send` /
  `task_recv` / `task_try_recv` / `task_kill`: unbounded FIFO mailboxes
  (Erlang-style; bounded/backpressure is a later add) with messages
  deep-copied across the boundary (share-nothing, like channels).
  `task_recv` blocks cooperatively on an empty mailbox — reusing the
  increment-1 suspend/resume machinery, delivered on wake — while
  `task_try_recv` is the non-blocking form. Sending to a finished or
  unknown task is a **silent drop** returning 0 (Akka dead-letters /
  Erlang cast — an error path here would be a nondeterminism magnet),
  not an error. `task_kill` tears a task down deterministically and
  wakes any joiner with an `interrupt` error. Still deterministic by
  construction (byte-identical across runs). Not yet: virtual time
  (`task_sleep`) and the pluggable seeded-strategy hook for the DST
  consumer.
- **Deterministic cooperative tasks — increment 1 (#408).** `task_spawn`
  / `task_yield` / `task_join` / `task_alive`: a single-OS-thread
  cooperative scheduler whose interleaving is deterministic **by
  construction** — no trace records, byte-identical across runs. Tasks
  are reified VM contexts (a copying-stack save-buffer per suspended
  task, not a 1.28 MB VM each); the JIT and non-atomic refcount fast
  paths stay live because the scheduler never flips the multithreaded
  flag. Args and results cross the boundary deep-copied (share-nothing,
  like channels). `task_join` returns the worker's result or re-raises
  its uncaught error as the same `{kind, message, line}`. All-tasks-
  blocked is a new `deadlock` error kind (loud, not a hang); suspending
  inside an `arena_mark`…`arena_reset` scope or a nested evaluation is a
  `value` error. Not yet: mailboxes/`task_send` (increment 2), virtual
  time, the pluggable seeded-strategy hook for the DST consumer.
  Increment 1c hardening: adversarial valgrind/ASan planted-fault
  verification proved the arena guard and the save-buffer teardown are
  load-bearing, and surfaced+fixed a real bug — a task ending inside an
  active arena scope arena-allocated its error dict (which crosses to the
  joiner) and left the arena active for the next task; `sched_finish` now
  forces the arena inactive. Determinism is a suite gate (two-run
  byte-identical), and SPEC gains an executable Tasks section.
- **E003 is scope-precise (#404, increment two)** — the undefined-name
  pass models the runtime's real scope rules instead of a whole-file
  binding set: function-locals (fresh-name `is` and `local`) are
  invisible to siblings and module code, closures read enclosing
  function scopes, nested `define` names are enclosing-local, and a
  module-level `for` loop-scopes its variable (a post-loop read is a
  runtime error the lint now catches; function-level `for` vars
  survive, matching the VM). Messages gain an edit-distance-1
  suggestion: `undefined name 'totl' — no binding on any path (did you
  mean 'total'?)`. Calibration: zero E003 across lib/, examples/,
  tests/ and all 10 consumer repos. External files (`load_file`
  targets, `# lint: loaded-by` composers) still contribute a flat
  over-approximated set. Path-precise "unbound on THIS path" analysis
  remains #404's last increment.
- **Structured runtime errors (#406, BREAKING)** — `catch` now binds a
  `{kind, message, line}` dict for built-in runtime errors instead of
  the flat `"Error line N: ..."` string: `kind` from a closed,
  SPEC-enumerated vocabulary (`undefined_name`, `type_mismatch`,
  `value`, `index_range`, `parse`, `io`, `limit`, `sandbox`,
  `interrupt`, `assert`, `internal`), `message` without the line frame,
  `line` 1-based. Discriminating error classes no longer means string
  matching. User-thrown values bind untouched, as before; uncaught
  stderr output is unchanged. Also: builtin raise sites now stamp the
  live source line (previously `Error line 0:`), `assert` failures are
  ordinary catchable errors (kind `assert`; caught asserts no longer
  print to stderr), `sandbox_run`'s result carries `"error": {kind,
  message, line}` when `ok` is 0, and the embed API gains
  `eigs_last_error_kind()` / `eigs_last_error_line()`. The kind table
  lives in docs/DIAGNOSTICS.md; SPEC.md Error handling rewritten with
  executable examples (suite EM26–EM30).
- **Parse errors print a source excerpt with a caret under the offending
  column (#407, increment two)** — for the column-carrying errors
  (`expected X, got Y`, one-statement-per-line), in the script runner,
  `--lint`, and the REPL. Additive: the `Parse error line N:C: ...`
  message is byte-unchanged, so substring-matching tools keep working.
  Remaining #407 scope: per-warning spans, runtime-error columns.

### Changed
- **Observer surface coherence (#412), two settled decisions.** (1)
  **Unity is the horizon**: the `|x| == 1.0` entropy special case is
  gone — the binary-entropy formula is smooth and maximal there
  (`H = 1.0`), so a value placed exactly at `1.0` reads like its
  neighbors (a flat run at `1.0` classifies `equilibrium`, never
  `converged`); `|x| == 0` keeps `H = 0`, the formula's own home-point
  limit. (2) **`how` is a real 0–1 gradient**: deadband-normalized
  settledness of the last observed step, `1 - min(1, |dH|/dh_zero)` —
  `1.0` = entropy unmoved, `0.0` = moved by the settle deadband or
  more. Pure in the recorded `dH`, so `how is x at L` reads identically
  from tape history (no tape format change). The old
  `1 - entropy/last_entropy` was degenerate (always `0` or `1`).
  OBSERVER.md's "Rough edges" caveats are closed as settled decisions.

### Added
- **JIT loop back-edges poll the async abort flag (#410)** — hard
  timeouts (`eigs_set_abort_flag`) now hold at full speed. The gap was
  the from-zero thunk: a call-hot function's loop closes natively via the
  backward patch and never crossed an interpreted back-edge (the OSR tier
  always re-entered through the interpreted `JUMP_BACK`, so it already
  polled). The emitter now plants a movabs/deref/cmpl poll before every
  native back-edge that bails to the interpreter at the `JUMP_BACK` when
  set — the interpreter consumes the flag and raises the ordinary
  catchable "aborted" error; no error machinery in native code. The flag
  pointer is now never NULL (unregistered points at a static zero), so
  both tiers poll with a single deref. Bench medians unchanged within
  noise (n=5: dmg_shape 326.3→323.4 ms, idxset 39.6→38.8 ms). The
  EMBEDDING.md / eigs_embed.h "JIT'd loops don't poll" caveat is deleted.
- **`# lint: loaded-by <relpath>` fragment directive (#460)** — a library
  fragment declares its composer (the entry point that `load_file`s it, or
  a concat sibling in out-of-language composition); E003 collects the named
  file's transitive binding set as context and lints the fragment against
  it. Kills the ~380 cross-module false positives the v0.27.0 consumer
  sweep hit (DMG 217→0, EigenMiniSat 99→0, verified on the real repos)
  while — unlike `# lint: allow-file E003` — a genuine typo in the fragment
  still fires. Repeatable, works in `--lint` and the LSP (which now passes
  the live document buffer through `lint_collect`, so as-you-type edits to
  the directive take effect), fails open on an unresolvable context.
  Documented in docs/DIAGNOSTICS.md.

### Fixed
- **A user rebinding of `dispatch` wins over the `OP_DISPATCH`
  superinstruction (#459)** — previously `define dispatch(a, b, c)` (or a
  plain `dispatch is ...`, including a write-through assignment inside a
  function body) was silently ignored at `dispatch of [t, k, a]` call
  sites: the compiler keyed on the name alone and emitted the fast path
  regardless of the binding. The superinstruction now steps aside — for
  any unit that binds `dispatch` anywhere or references `eval` (dynamic
  escape), and for a REPL/embed unit compiled against an env where the
  name is already rebound — failing open to the semantically identical
  normal call path. The parenthesized `dispatch of ([t, k, a])` form now
  also takes the normal path (one argument, per the #355/#405 contract).
- **W012/W013 (builtin shadowing) derive from `register_builtins()`
  itself, not a hand list (#459)** — the old hand-copied array was ~120
  names behind the binary, so shadowing `dispatch`, `chr`, `eval`, and
  every other post-list builtin lint'd clean. Same derivation as E003's
  binding base, plus the extension names (`ext_names.h`).

### Changed
- **Decided (#459): `report`, `report_value`, and `observe` on a plain
  variable are observer special forms** — compiler-resolved to the named
  binding's slot trajectory, like the predicates and interrogatives; a
  user rebinding does not change them (W013 now warns on the attempt).
  Documented in BUILTINS.md and DIAGNOSTICS.md.

## [0.27.0] - 2026-07-06

### Changed
- **BREAKING — one call rule (#405, closes #153): a bare literal list
  after `of` is ALWAYS an argument list**, at every element count:
  `f of []` is zero arguments, `f of [x]` is ONE argument (the element —
  previously it bound the whole 1-element list to the first parameter),
  `f of [a, b]` is two. Brackets are an argument list; parentheses are
  one argument — `f of ([x])` (#355) still passes a literal list whole.
  The obvious recursive form `fib of [n - 1]` now works even after a
  defaulted parameter is added (the arity-dependent silent-wrong this
  kills). Migration: every behavior-changed site is a bare 1-element
  literal arg list — the new **W017** lint flags exactly that shape with
  the two unambiguous rewrites (`f of x` / `f of ([x])`), so `--lint`
  over a repo is the mechanical audit. SPEC/COMPARISON call sections
  rewritten.

### Added
- **W017 — bare 1-element literal arg list** (#405): warns on `f of [x]`
  (historically ambiguous; inverted meaning pre-#405) and names both
  unambiguous spellings — `f of x` for one argument, `f of ([x])` to
  pass a 1-element list. Doubles as the #405 migration audit over a
  consumer repo.
- **E003 — undefined-name lint, increment one of the scope-aware
  name-resolution pass** (#404): `--lint` (and the LSP, as red squiggles)
  now reports a name that is read but bound nowhere — the typo'd name in a
  cold branch that a dynamic language otherwise carries to runtime. The
  binding set is a deliberate whole-file over-approximation (silent on
  outward-`is`, `local` shadowing, sibling-branch first assignment; a false
  positive is the failure mode that breaks consumer CI, so the pass always
  fails open). Builtins come from `register_builtins()` itself on a scratch
  env — never a hand list (the old lint.c copy had drifted ~120 names and
  carried a phantom `"error"` entry). Extension builtins bind by name via
  the new `src/ext_names.h` X-lists, which the gfx/http/db/model registrars
  now expand too, so registration and name-resolution cannot drift; the
  lint describes the language surface, not one binary's build flags.
  Literal `load_file of "path"` is resolved with the runtime's own
  resolution chain and its top-level binders collected transitively, so
  entry-point files assembling a program from parts lint clean. `eval` or a
  computed `load_file` path disables the pass for the file (documented
  dynamic escape). E003 is error-severity: it fails `--lint` even at
  `--lint-level error`. Full model in docs/DIAGNOSTICS.md.
- **`# lint: allow-file <CODE>...` file-wide suppression** — the escape for
  module *fragments* (files a loader `load_file`s into scope the loader
  provides, e.g. `lib/ui_w_*.eigs`), honored by both `--lint` and the LSP.
  `lib/invariant.eigs` instead became self-contained (it now loads
  `lib/observer.eigs` for `cs_signature` — pure defines, idempotent).
- **Interactive REPL line editor** (#392) — the REPL on a tty now has
  history (in-memory + `EIGS_HISTORY` file, default
  `~/.eigenscript_history`, created `0600`), arrow-key cursor editing,
  Home/End/Delete, Ctrl-A/E/U/K/W/L, Ctrl-C line-and-block cancel, and tab
  completion over builtins + session bindings (both are env bindings, so
  one walk covers them). Zero new link dependencies: a raw-termios editor
  in the new CLI-only `src/repl.c` (ported from the EigenOS console
  editor), not readline/libedit — the embed/freestanding profiles never
  see it. Piped/non-tty sessions keep the old fgets loop byte-for-byte
  (`EIGS_REPL_PLAIN=1` forces it on a tty). Interactive sessions record
  assignment history from the start, so `prev of x` works on session
  bindings instead of silently answering from no history. Suite section
  [42c] drives the editor on a real pty (`tests/test_repl.py`) and pins
  the piped transcript as a byte-exact golden.

### Fixed
- **Four silent-wrong-answer builtin contracts** (#312, #314, #316, #317),
  batch-fixed after the 2026-07 backlog triage:
  - `min`/`max` are now true N-ary reductions over a flat list of numbers
    (#317). The old code read only the first two elements — `max of [1, 2, 3]`
    returned **2** — and returned `0` for a 1-element list. Now
    `min of [5]` → `5`, `max of [1, 2, 3]` → `3`, and a bare number returns
    itself (mirroring `sum`); an empty list or a non-number element keeps
    the documented `0` fallback.
  - The string predicates `index_of`/`contains`/`starts_with`/`ends_with`
    reject non-string operands (#316) instead of folding them to `""`,
    which spuriously matched everything (`index_of of [[1,2,3], 2]` returned
    `0` — "found at index 0" — in violation of its "or -1" contract). Misses
    now answer `-1` (`index_of`) / `0` (the predicates).
  - `get_at`/`set_at`/`char_at` honor negative indices exactly like the `[]`
    operator (#312) — `get_at of [xs, -1]` is the last element (was: silent
    `0`/no-op/`""`), including the 2-D `get_at`/`set_at` row/col paths.
    Out-of-range indices keep the old miss defaults.
  - Passing a directory as the script path exits `1` with the clean
    `Error: cannot read file '...'` path (#314) instead of SIGABRT via a
    bogus 9-exabyte `xmalloc` (`ftell` on a directory reports `LONG_MAX`);
    `read_file_util` now rejects non-regular files up front, which covers
    `load_file` and the `--fmt`/`--lint` paths too.

### Changed
- **`chr` is the byte-writing inverse of `ord`** (#435): `chr of n` now emits
  the raw byte for any integer 1–255 (was: silent `""` for anything above
  127). Everything else raises loudly — 0 (strings are NUL-terminated),
  negatives, fractions (previously truncated silently), values above 255
  (the error points at `utf8_encode` for codepoints), and non-numbers.
  `chr of n` == `str_from_bytes of [n]` across the shared range.

### Added
- **Trace-tape format versioning** (#411): every tape now opens with a
  `V <format> <runtime>` header (both the hosted `EIGS_TRACE` file and the
  embed sink), and replay refuses a tape whose format or runtime version
  doesn't match the running binary — missing/malformed/mismatched headers
  exit with status 3 (hosted) or reject the tape at `eigs_set_replay_tape`
  (embed, returns 0). Version-and-reject, no migration, no override flag;
  the decision and the residual dev-build honesty gap are recorded in
  docs/TRACE.md. Pre-#411 (headerless) tapes are no longer replayable.
  Hardened by adversarial review: an unopenable `EIGS_REPLAY` path is now
  fatal too (was warn-and-run-live — the same silent divergence); the
  embed install validates *every* session header of a concatenated
  journal up front and swaps atomically (a refused/OOM install leaves the
  previously active tape and strict mode untouched, and can never abort
  the host mid-eval); torn mid-stream `V` lines refuse instead of
  slipping through the record filter; and `--version`/`--help` are
  handled before `trace_init` so a stale exported `EIGS_REPLAY` can't
  take down pure queries.
- **W016 — bare-predicate aliasing fence** (#396, completing it): a bare
  trajectory predicate outside a loop condition (`if stable:`,
  `ok is converged`, `return diverging`) reads the last-observed binding —
  the #247/#262 invisible-alias family — and now warns: write
  `<predicate> of <var>`. Loop conditions stay exempt (single-assign
  `loop while not converged` is the documented idiom; the ambiguous
  multi-assign case is already W014, no double-fire). Any explicit subject
  counts as named (incl. the `stable of (x + 0.0)` #262 workaround);
  deliberate bare reads use `# lint: allow W016` (#399). Zero firings
  across `lib/` + `examples/` and the consumer corpora; surfaces in
  `--lint --json` and eigenlsp via the shared pipeline.
- **`utf8_encode` / `utf8_from_codepoints`** in `lib/utf8.eigs` (#435): the
  encode half of the #416 module — codepoint(s) → UTF-8 byte string, built on
  `str_from_bytes`. #435's premise was a misdiagnosis: high bytes were already
  constructible via `str_from_bytes` (#248); encode had been omitted on that
  mistaken belief.
- **Parse errors carry `line:col`** (#407, first increment): the lexer already
  tracked columns; now the two parser diagnostics surface them. Human output
  reads `Parse error line 6:9: …`, the `--lint --json` `E002` element gains a
  1-based `"column"` field, and the LSP diagnostic range starts at that column
  instead of 0. Per-warning spans, runtime-error columns, and caret rendering
  remain the rest of #407. (`docs/DIAGNOSTICS.md` records the `--json` contract
  change.)
- **`observer_slots.verdict of i`** — the full trajectory-regime string for a
  slot (was deferred on #383). Investigating #383 showed `report of <name>`
  inside a function *does* resolve the module binding's slot correctly and agrees
  with the predicates — the reported divergence did not reproduce (it was a
  constant reading as "equilibrium", which also satisfies `stable`, misread as a
  resolution bug). Verified with a descending signal reading "improving" (not the
  value-fallback), single-file and via `load_file`. Suite [50i] now 11 checks.
- **Unicode/text position settled: bytes-forever + `lib/utf8.eigs`** (#416).
  SPEC.md gains a "Text" subsection making `str`-is-a-byte-string official — byte
  indexing, multibyte-safe concat/f-strings — with byte-checked examples, and the
  new `lib/utf8.eigs` gives character semantics over the byte string
  (`utf8_len`/`utf8_codepoints`/`utf8_at`/`utf8_char_at`/`utf8_validate`, tested
  against published U+00E9/U+20AC/U+10348 vectors, suite [50k]). Native
  UTF-8-by-construction is deliberately not adopted (it would ripple through
  VM/JIT/AOT/tools). Building the module surfaced a real gap, filed rather than
  worked around: `chr` can't emit bytes ≥ 0x80, so `utf8_encode` (and byte-output
  generally) waits on #435.
- **Numeric model documented as a deliberate position** (#417): SPEC.md gains a
  "numeric model" subsection stating the contracts one f64 number kind buys —
  integer exactness ends at 2^53, arithmetic is finite by construction (`NaN`
  collapses to `0`, overflow saturates at ±1e308, never `Infinity`), and integer
  bitwise ops act on int64 (exact past 2^32) — with byte-checked examples. The
  decision: no bigint/decimal until a consumer forces it (it would ripple through
  the JIT and AOT); the wording avoids overcommitting "num IS f64" so a future
  wider kind stays possible. Roadmap item updated from a one-liner to the decided
  position.
- **`bench/` perf harness + a regression-gated `docs/PERFORMANCE.md`** (#398):
  performance as an executable, gated fact rather than a README claim. Two
  metrics on purpose — `bench/run_bench.sh` reports wall-clock n=5 medians (the
  human-facing PERFORMANCE.md numbers, environment-dependent), while the CI gate
  (`bench/check_regression.sh`) compares **deterministic cachegrind instruction
  counts** of the commit against origin/main, both built in the same runner, so a
  regression is a diffable fact and the gate never flakes on runner load. A
  `--selftest` builds a 2x-work workload and asserts it is flagged (the gate
  isn't vacuous). Workloads include observed-vs-unobserved, making the observer
  cost an executable document: ~28% wall-clock / ~46% instructions.
- **`docs/llms.txt` — single-file language reference for LLMs** (#403): the whole
  surface a model needs to generate correct `.eigs`, distilled to the traps
  where Python/JS habits fail — the `of`/one-element-spread rule, the
  outward-mutating scope model (`local` in helpers), reserved/soft keywords, the
  observer idioms, and an explicit **generate-then-validate ladder**
  (`--lint --json` → run → `--test`, the parse→compile→sandbox grading). Linked
  from the README; a doc-drift check stamps it to the current version so it
  can't silently fall behind the language. (Writing it caught a wrong idiom in
  its own draft — `1/0` warns and returns 0 rather than throwing, so the
  try/catch example now raises with `throw of` explicitly.)
- **COMPARISON.md "Convergence loops" section** (#402): the observer's everyday
  payoff, framed as boilerplate deletion before any theory — the same Newton's
  square root in Python (hand-rolled epsilon threshold, remembered previous
  value, max-iteration guard) versus EigenScript's `loop while not converged`,
  byte-checked under the doc-examples gate. New
  `examples/observer_vs_boilerplate.eigs`; README links the pragmatic comparison
  ahead of the OBSERVER.md theory.
- **First-run tooling unification** (#400): `install.sh` now builds and installs
  the `eigenlsp` language server alongside the interpreter (via a new
  `./build.sh lsp` mode, gcc-only, reusing build.sh's source list). The two
  parallel VS Code extension trees are collapsed into one canonical
  `editors/vscode/` that ships `extension.js` — a bundled client auto-launching
  `eigenlsp` on `.eigs` files; the drifted `editor/` duplicate is deleted. A new
  `install-smoke` CI job asserts the canonical tree wires the LSP client and that
  a fresh `install.sh` leaves both binaries on `PATH`.
- **docs/CONCURRENCY.md + a ThreadSanitizer race gate** (#401): the memory-model
  contract, written down at last — messages (channel sends, joined results) are
  deep-COPIED (`val_clone_for_send`, share-nothing); a spawned closure SHARES the
  parent heap by reference (races are yours); the first `spawn` flips the runtime
  to interpreter-only (#297 gates the JIT/OSR/IC off — the MT perf cliff); and
  `recv`/spawn handles raise loudly under `EIGS_REPLAY` (#148). Its examples are
  byte-exact under the doc-examples gate ([89]). The #297 "TSan-clean" claim was
  only a code comment; now `make tsan` + `tests/test_tsan.sh` (CI `tsan` job)
  run the spawn/channel slice under ThreadSanitizer (`setarch -R`) and prove it
  race-free — and a deliberately seeded race (`tests/tsan_seeded_race.eigs`) is
  asserted to be caught, so the gate can't rot into a vacuous pass.

### Fixed
- **Infix shift undefined behavior — shift counts now masked `& 63`.** The
  `bit_shl`/`bit_shr` builtins already masked the count to `[0,63]`, but the
  infix `<<`/`>>` operators did not: `1 << 64` (and any count ≥ 64 or a negative
  count) was C undefined behavior on the `int64` path. No suite case exercised a
  count ≥ 64, so UBSan stayed quiet over a real latent bug. Both paths now mask
  identically, honoring the `docs/LANGUAGE_CONTRACT.md` "shifts are defined, not
  UB" promise; `tests/test_bitwise.eigs` gains the ≥ 64 cases for the infix
  operators (`1 << 64 == 1`, `1 << 100 == 2^36`) proving parity with the
  builtins. Behavior on x86-64 is unchanged (the hardware already masked mod-64);
  the fix makes it defined rather than accidental.
- **Data race in `channel_closed`** — it read `ch->closed` without the channel
  mutex while `close_channel` wrote it under the lock. Single-core timing hid it
  locally; the new #401 TSan gate caught it on its first CI run (two workers
  polling `channel_closed` against a concurrent `close`). Now reads under the
  lock. This was the one real gap behind the "#297 TSan-clean" claim.
- **`--lint` severity control + inline suppression** (#399): `--lint-level
  error|warning` chooses the exit-1 threshold — `error` makes warnings advisory
  (still printed / in `--json`, but exit 0 unless an error-severity diagnostic
  is present), so a consumer can wire `--lint --json` into CI for diagnostics
  without warnings-as-errors. A `# lint: allow W001` comment (space/comma-
  separated codes, or `all`) silences those codes on its line and the line below
  — trailing or above the flagged construct — removing them from human and
  `--json` output. docs/DIAGNOSTICS.md "Severity control and suppression";
  test_lint.sh both-ways coverage. (This is the suppression escape hatch W016
  was waiting on.) Per-file `eigs.json` allow-lists remain open on #399 as a
  contributor on-ramp.
- **`make lib` + two-file amalgamation — the embeddable artifact** (#397):
  `make amalgamation` writes `build/eigenscript_all.c` (every runtime source and
  header inlined into one self-contained translation unit, optional extensions
  defaulted off) plus the public `build/eigs_embed.h`. Copy the two files and
  compile with `cc` alone — no `-I`, no `-D`, no source list — the Lua-grade
  drop-in. `make lib` produces `libeigenscript.a`. The amalgamator reads its
  source list from the Makefile's `SOURCES` (no second list to drift), and
  `make embed-smoke` now links against the amalgamation so the artifact can't
  silently rot. New "Drop-in" quickstart in docs/EMBEDDING.md;
  tests/test_amalgamation.sh proves the fresh-dir `cc`-alone build; CI covers
  `make lib` and the drop-in.
- **`--test --trace-on-fail` — every failure is a replayable tape** (#394):
  records each test into its own tape via a new `--trace <path>` CLI flag (the
  twin of `EIGS_TRACE`). A passing test discards its tape; a failing one keeps
  it and prints the exact `EIGS_REPLAY=<tape> eigenscript <file>` invocation that
  reproduces the failure byte-for-byte — the same random draw, clock read, and
  file bytes come off the tape. `--json` results carry a per-test `tape` field
  for CI archival. Proven by a transcript byte-diff oracle
  (`tests/test_trace_on_fail.sh`, suite [42b]) on both execution tiers (JIT on
  and `EIGS_JIT_OFF`) and under `EIGS_REPLAY_STRICT`; new "Every Failure is a
  Tape" section in docs/TRACE.md with the same-binary (#411) caveat; a CI leg
  records and uploads a tape artifact.
- **Lint W015 — function-clobber fence** (`src/lint.c`, advances #396): a
  function that assigns (without `local`) over a module-level *function* name
  silently reassigns it via mutate-outward, so later `<fn> of ...` calls fail.
  W015 flags exactly that. It is deliberately scoped to function clobbering: the
  broad "any outer mutation" reading is refuted by the corpus — under
  mutate-outward, reusing a generic module *variable* name inside a function is
  pervasive and almost always benign (155 such firings across working examples),
  so flagging it would be noise. `_`-prefixed names (intentional module state,
  as W001 already honors) are skipped. The general local-discipline lint is
  #404's dataflow-aware territory. Surfaces in the editor via the shared
  `lint_collect` path; docs/DIAGNOSTICS.md entries for W014 and W015 (W014 was
  missing). Firing + non-firing fixtures in test_lint.sh; zero false positives
  across lib/ + examples/.
- **Stdlib/builtin discoverability gate** (`tools/stdlib_index_check.sh`, #393):
  every builtin registered in `src/builtins.c` must appear in the reference docs
  (BUILTINS.md / SPEC.md / STDLIB.md) and every `lib/*.eigs` module must have a
  STDLIB.md heading — undiscoverable breadth is zero breadth. The gate ships a
  `--selftest` proving it flags an injected undocumented builtin, and runs in the
  suite as [99b] beside the doc-drift gate. Backfilled the six builtins it caught
  (`dispatch`, `nearest_in_range_all`, `proc_read_buf`, `read_bytes`, `reshape`,
  `secure_equals`) into docs/BUILTINS.md.
- **`lib/contract.eigs`** — trajectory contracts (#395): `require`/`ensure`
  (plain predicates) plus the observer-native differentiators
  `expect_converging`, `expect_monotone`, and `invariant_stable`. Each drives a
  seed through a one-arg step function into an observed local and asserts a
  property of that trajectory — convergence/monotonicity/stability — that no
  type grammar can state. Two observer truths are baked in: convergence is read
  on the **value channel**, because a monotonically exploding value reads
  `converged` on the entropy channel (the #294 blind spot — a contract `report`
  would silently pass); and a non-scalar accumulator is refused loudly rather
  than classified `equilibrium` forever as a silent no-op. Worked solver:
  `examples/stem/contract_solver.eigs`; new "Contracts" section in
  docs/OBSERVER.md; suite [50j]. An adversarial verification sweep hardened the
  module: the scalar guard fires on every step's output (not just the seed), a
  `max_obs` below the observer window is rejected rather than vacuously passing,
  and `expect_converging` requires a genuine "converged" verdict instead of
  accepting a "stable" slow-runaway. Surfaced two upstream gaps rather than
  working around them: #421 (the observer slot is binding-identity, so a value's
  history can't be inspected by a function it is passed to) and #422 (the value
  channel's relative-delta normalization is blind to sub-exponential divergence
  and sub-deadband oscillation).

### Fixed
- **`lib/tensor.eigs` — `xavier_init`/`he_init` clobbered the module `scale`
  function.** Both used a bare `scale is ...` local; because `scale` is also a
  top-level function, mutate-outward destroyed it, so a `scale of [t, s]` call
  after either initializer would fail. Now `local scale`. Found by the new W015.

## [0.26.0] - 2026-07-04

### Added
- **Stdlib backlog train** (from the cross-repo pattern survey):
  `lib/bcd.eigs` (packed BCD any width, loud rejection of invalid
  nibbles — CMOS RTC + Game Boy DAA), `functional.wait_until` (the
  bounded-poll shape; caller supplies the sleep primitive),
  `format.hexdump` (offset/hex/ascii rows over strings or buffers),
  `lib/harness.eigs` (the count-and-continue twin-gate scaffolding
  extracted from six hand-rolled EigenOS harnesses), and
  `lib/observer_slots.eigs` (eight named observer slots behind index
  dispatch — the #262 trajectory-identity trap encoded once; verdict()
  deferred on the #383 report-of resolution asymmetry found while
  building it). Suite sections [50e]-[50i].
- **`lib/checksum.eigs`** — CRC-32 (reflected 0xEDB88320, table-driven),
  Adler-32, and `sum8` over strings or buffers; results unsigned 32-bit.
  Byte-integrity math written once: regionfs hand-rolls Adler-32 today,
  DMG needs the cartridge header sum, M13 networking wants CRC-32.
  Suite [50c] pins the published check values.
- **Civil-date math in `lib/datetime.eigs`** — the module's first PURE
  half (the clock functions shell out to `date` and are host-only):
  `days_from_civil`/`civil_from_days`, `weekday_from_days`,
  `epoch_from_civil`/`civil_from_epoch` (Hinnant's algorithms, exact
  integer arithmetic in doubles, every profile). EigenOS's rtc.eigs is
  the motivating consumer — CMOS registers to epoch seconds with no
  host clock. Suite [50d] pins leap edges and round-trips.

### Fixed
- **The `bit_*` builtins are now the same operation as the infix
  operators.** They were a second, divergent implementation — a
  `(uint32_t)(int32_t)` conversion that was undefined behavior for
  inputs ≥ 2^31 and sign-extended results — so `0xEDB88320 & x` worked
  while `bit_and of [0xEDB88320, x]` returned garbage (found by the
  CRC-32 stdlib module, the first consumer needing the full unsigned-32
  range). All six builtins now use the infix int64 two's-complement
  semantics; shift counts are real up to 63 (the old int32-era `&31`
  count masking — `bit_shl of [1, 32]` == 1 — is gone). test_bitwise
  gains an infix-vs-builtin equality battery over the high-bit range.
- **`num of` hex strings share the lexer's contract.** The string→number
  builtin delegated wholesale to `strtod`, so `num of "0x.8"` read 0.5
  and `num of "0x1p4"` read 16 hosted while the freestanding profile
  read 0 — the #378 divergence surviving through the string path. Hex
  strings now convert in the builtin itself on every profile: integer
  digits, stop at the first non-hex character ("0xFFzz" → 255,
  "0x1p4" → 1), prefix with no hex digit → 0 like any non-numeric
  string. Suite [50b] gains five conversion checks.

## [0.25.0] - 2026-07-04

### Added
- **Async abort seam for embedders** (`eigs_set_abort_flag`). The host
  registers a flag it may set from an interrupt/signal context (SIGINT
  handler, timeout timer, bare-metal keyboard IRQ); the interpreter polls
  it on every loop back-edge and raises an ordinary `aborted` runtime
  error, consuming the flag — one set aborts exactly one eval and the
  state stays usable. Setting the flag is a plain store into the host's
  own int (async-signal-safe; the runtime only reads). Unregistered cost
  is one predicted-not-taken test per back-edge. Documented caveats:
  catchable like any runtime error; JIT/OSR-native loops don't poll
  (freestanding compiles the JIT out, so bare-metal coverage is total).
  Motivated by EigenOS: ctrl-c must break a runaway eval at the metal
  REPL instead of owning the machine. Covered by embed_smoke (pre-set +
  mid-eval interval-timer cases) and docs/EMBEDDING.md.

### Fixed
- **Hex integer literals are lexed explicitly, not delegated to `strtod`.**
  `0xFF` previously parsed only because glibc's C99 `strtod` accepts hex —
  the freestanding profile (mini_strtod, deliberately hex-free) lexed the
  same source as `0` + identifier `xFF`, so hex-using programs parsed
  hosted and broke on EigenOS (found by its M12 PCI port-I/O probe). The
  lexer now consumes `0x`/`0X` + hex digits itself on every profile, and
  the accidentally-accepted hex-FLOAT forms (`0x1p4`, `0xA.8`) are loud
  parse errors instead of numbers. New suite section [50b] pins the form.

## [0.24.0] - 2026-07-03

### Performance
- **Frameless leaf-accessor calls (#366).** Function chunks whose body is a
  single pure expression over their params — field gets, list/buffer index
  gets, numeric arithmetic, numeric constants ending in `return` — are
  flagged at compile time (`chunk_scan_leaf_accessor`) and exactly-fed calls
  execute directly against the caller's stack (`vm_leaf_accessor_exec`): no
  call env take/rebind/park, no frame push, no chunk refcount traffic, no
  dispatch in/out of the callee. Any runtime surprise (type mismatch,
  out-of-range index, missing-field chain) bails to the generic CALL path
  before touching the stack, so results, errors, and tracebacks are
  byte-identical. Measured on the EigenMiniSat-derived accessor micro-bench
  (200K-iteration loop, n=5 medians): call overhead vs the inlined
  expression drops from ~198ns to ~40ns per call (+44% loop penalty →
  ~+7%). Hooked in both the interpreter's `CASE(CALL)` and
  `jit_helper_call`, so interpreter-tier consumers (EigenOS) and JIT'd
  loops both benefit.

### Added
- **`hex of n` / `hex of [n, nibbles]` builtin.** Uppercase hex of a
  non-negative integer, optionally zero-padded (never truncated); raises
  on negatives, fractions, and non-numbers. Demanded by the emulator
  repos (DMG GAP-DMG-010) — addresses/opcodes/registers all want hex
  diagnostics and every consumer hand-rolled it.
- **Audio channel mixer: `audio_volume`, `audio_stop`, infinite loops
  (Tidepool GAP-002/GAP-003).** The audio device now runs a 16-channel
  callback mixer instead of SDL queue mode. `audio_play` /
  `audio_play_loop` return a channel id; `audio_play_loop of [clip, -1]`
  loops forever (the mixer rewinds — loop count no longer multiplies
  memory, so the old 256 MiB loops×len budget is gone);
  `audio_volume of [ch, vol]` adjusts a playing channel live (0.0–4.0);
  `audio_stop of ch` stops one channel. The pool always succeeds —
  when all 16 channels are busy the oldest finite one is recycled
  (callers historically ignore the return value, so refusal would be
  silent). `audio_queue_size` now reports unplayed bytes across active
  finite channels; `audio_clear` stops everything. Channel state is
  mutated only under `SDL_LockAudioDevice`.
- **Trace-tape seam in the embed API.** `eigs_set_trace_sink` streams every
  tape record (L/A/N lines) to a host callback as bytes, enabling recording
  with no filesystem; `eigs_set_replay_tape` hands a whole tape back as the
  in-memory replay source (nondet builtins serve the recorded `N` values in
  order, falling back to live at tape end); `eigs_replay_take` /
  `eigs_trace_record_nondet` let HOST-registered builtins participate in
  the tape with the same take/record contract the runtime's own nondet
  builtins use. This un-carves record/replay for the freestanding profile
  (EigenOS M11: the machine journal targets the M10 store). Hosted
  EIGS_TRACE / EIGS_REPLAY behavior unchanged; the strict-mismatch abort
  uses `abort()` freestanding (`_exit` is hosted-only). Covered in
  `embed_smoke.c` (record → sink, sink-off freeze, replay-served values vs
  an advancing live source, tape exhaustion, clear), documented in
  docs/EMBEDDING.md.
- **Buffer support in the embed API.** `eigs_value_new_buffer` /
  `eigs_value_buffer_len` / `eigs_value_buffer_get` / `eigs_value_buffer_set`
  plus `EIGS_TYPE_BUFFER` in the type enum — the script-side `buffer of n`
  value crossable at the host boundary with no copy (a host-built buffer
  passed to script is the same object `buf_set` mutates). Buffers are the
  NUL-safe binary carrier: this is the seam a block-device embedder
  (EigenOS M10, tidelog-as-filesystem) moves sectors through. Covered in
  `embed_smoke.c` (construction, OOB/wrong-type safety, shared-object
  mutation both directions), documented in docs/EMBEDDING.md.
- **Single-thread multi-state switching (`eigs_thread_switch`).** Parks the
  calling thread's current attachment (no teardown — arena, freelists, VM
  and error state live on the `EigsThread` and stay intact) and activates
  its attachment to another state, creating one on first switch; vm.c's
  `__thread` hot caches are reset per switch exactly as attach does. This is
  the cooperative-scheduler seam (EigenOS M9: a task IS an `EigsState`; a
  step is one eval; the scheduler is script). Rules: values never cross
  states (copy numbers out); `eigs_close` must run while attached to the
  closing state. Covered in embed_smoke: isolation both ways, bindings
  preserved across switches, process-global source provider serving every
  state, close-and-reactivate.
- **Embedder source provider — the module seam (`eigs_set_source_provider`).**
  `import name` now consults a host-registered provider FIRST in every build
  profile; the filesystem chain is the hosted fallback and is absent in the
  freestanding profile, where the provider is the only module source. This is
  the seam EigenOS's M7.5 "ROM bundle" plugs into (stdlib + programs baked
  into the kernel image, `import` working on bare metal with no filesystem —
  later re-backed by a real filesystem without changing the interface).
  Provider-served modules share the module cache (keyed under a
  `\x01provider:` prefix no real path can collide with); the provider's
  returned pointer is copied immediately, so static strings are ideal. The
  freestanding `import` error now names both causes. Covered hosted
  (embed_smoke) and freestanding (freestanding_smoke).

### Changed
- **Module functions can no longer bind writes through to the loader's
  globals (#373).** Whether a `load_file`'d (or `import`ed) module's
  function could clobber a caller global used to depend on load order:
  a global declared *before* the load was a compile-time write-through
  target (`in_globals` probed the live env during the module compile),
  one declared *after* was insulated — so a library's stray bare
  assignment silently corrupted exactly those caller globals that
  existed at load time (EigenRegex#5: the caller's `pos is 42` broke
  the regex engine's own matching). Module compiles now set a boundary
  flag: function-body writes to names that aren't local / captured /
  outer / the module's own top-level state compile as fresh locals,
  never as dynamic writes through the loader's env. Reads and calls
  still resolve dynamically across the boundary (cross-module reads,
  caller-provided hooks, and value mutation via index all work
  unchanged), top-level module statements still execute in the current
  scope, and same-file outward mutation — the documented scope model —
  is untouched. Compile-time only; zero runtime cost. The one stdlib
  consumer of the old write-through — the UI toolkit's 23 bare globals
  shared across its 18 files — migrated to a single `_ui` state dict
  (reads cross the boundary; field writes are value mutations), which
  is now the documented cross-file shared-state pattern (SPEC.md
  "Module write boundary").

### Changed
- **Parentheses always mean one argument (#355).** A parenthesized
  literal list no longer spreads: `f of ([a, b])` binds the whole list
  `[a, b]` to the first parameter, exactly as SPEC.md's `f of (x)`
  guidance always promised (previously parens were AST-transparent and
  the literal spread anyway, leaving **no syntax** to pass a literal
  2+-element list as a single argument to a multi-parameter function).
  `f of ([])` is likewise a one-argument call passing the empty list;
  bare `f of []` remains the zero-arg form and bare `f of [a, b]`
  still spreads. The meta-interpreter (lib/eigen.eigs) mirrors the rule
  (test_meta_parity), and SPEC.md / LANGUAGE_CONTRACT.md / COMPARISON.md
  document it. The ouroboros AOT frontend mirrors this at its next
  runtime-pin bump, per the #326/#328 precedent.

### Fixed
- **`--lint` no longer reports false-positive `unused parameter` for
  uses inside `unobserved:` blocks (dynamics F-DYN-4).** The lint
  walkers didn't descend into `AST_UNOBSERVED` (same block shape as
  `AST_BLOCK`), so a parameter referenced only inside an `unobserved:`
  hot loop looked unused; `AST_SLICE` and `AST_LIST_PATTERN_ASSIGN`
  operands were invisible to use-analysis the same way. All three now
  traverse.
- **Parser caps fail loudly at the cap (#354).** A 17-parameter
  `define`/lambda or a 65-case `match` used to stop consuming at the cap
  and die in a stray-token error cascade that never mentioned the limit —
  a real hazard for generated code. Each now produces exactly one parse
  error naming the cap (`function exceeds 16 parameters`, `lambda exceeds
  16 parameters`, `match exceeds 64 cases`), draining the excess input so
  the diagnostic stands alone. The caps are now named constants
  (MAX_PARAMS, MAX_MATCH_CASES) and documented in SPEC.md's new
  "Syntactic limits" note alongside the existing 1024-element list cap.
- **ext_db raises instead of silently mangling queries (#356).** A query
  list with 17+ parameters silently dropped the extras (Postgres would
  then error confusingly at exec time, or worse, not at all), and a
  non-string/number parameter was silently sent as `""` (the #316
  coerce-to-empty class). Both now raise catchable errors naming the
  problem (`db: too many parameters (N, max 16)`, `db: parameter N is
  not a string or number`).
- **ext_http route registration raises on failure (#356).** A malformed
  route argument or the 257th route returned a silent `make_null()` that
  no caller checks — the route just never existed. Both now raise
  (`http_route requires [method, path, handler...]`, `http_route: route
  table full (max 256 routes)`).
- **gfx: `ppu_render_frame` window uses an internal line counter.** The
  window's row advances only on scanlines where it actually renders
  (resetting each frame), replacing the `ly - wy` approximation that
  misrendered mid-frame window toggles/WY changes. In lockstep with the
  script-PPU twin (DMG#18).
- **gfx: `ppu_render_frame` gates the window layer on LCDC bit 0.** On DMG
  hardware, LCDC bit 0 = 0 disables the window as well as the background;
  the native renderer drew the window whenever bit 5 was set. Kept in
  lockstep with the script-PPU twin (DMG#31).
- **`sort` no longer silently no-ops on non-numeric lists (#368).** The
  comparator returned 0 for any non-number pair, so sorting a list of
  records did nothing — with libc-dependent element order, since qsort
  guarantees nothing for all-equal elements. DMG shipped two
  silently-unsorted call sites on this (sprite X-priority — the very use
  case `sort` was added for — and input-script ordering; DMG#25/#26).
  `sort` now sorts all-number lists numerically (unchanged), sorts
  all-string lists lexicographically (making `lib/test_runner.eigs`'s
  directory discovery deterministic), and **raises** on mixed or
  non-scalar elements, naming the offending index/type and pointing at
  `sort_by` (stable, numeric-keyed) for records.
- **The compiler no longer costs ~12.7 KiB of C stack per AST level — the
  EigenOS "#UD heisenbug" root cause.** `Compiler` embedded
  `Local locals[512]` (12 KiB) by value, and `compile_node_inner`
  stack-declares a `Compiler` for every nested function — so compiling even
  a 5-deep AST used ~64 KiB of C stack. Hosted 8 MiB stacks never noticed;
  on EigenOS's 64 KiB boot stack the overflow (no guard page on bare metal)
  silently trampled the `.bss` sections below the stack, producing the
  layout-sensitive delayed `#UD` wild-dispatch documented in EigenOS
  KNOWN_ISSUES — the fault was deterministic per build, moved with every
  rebuild, and survived heap/stack zeroing, which had mis-pointed the
  diagnosis at an uninitialized read. Poison-fill (`make poison`, new) +
  `MALLOC_PERTURB_` + Valgrind on a new embed-API REPL soak exonerated the
  allocation layers, and rerunning the soak under `ulimit -s 64` reproduced
  the crash hosted in `compile_node_inner`'s prologue. The `locals` array is
  now heap-allocated per compiler (`compile_node_inner` frame: 12,704 →
  1,440 bytes; `compile_ast`: 12,576 → 304; worst-case compile stack at
  `COMPILE_MAX_DEPTH` 128: ~1.6 MiB → ~184 KiB). Regression:
  `tools/embed_stack_soak.sh` (CI, freestanding job) runs a 104-step
  REPL-accumulation soak through `eigs_eval_string` — the pattern the suite
  never exercises (one script per process) — inside a 64 KiB stack rlimit;
  it SIGSEGVs without this fix.

### Added
- **`make poison` — uninitialized-read hunter build.** Fills `xmalloc`
  blocks, `xrealloc` grown tails, and the env freelist's parked dormant
  arrays (`names`/`values`/`assign_counts` + hash `hashes`/`indices`; the
  generation gate itself is untouched) with `0xAA`, so a read of
  never-initialized or stale-gated memory misbehaves deterministically on
  every link layout instead of reading glibc's benign zero pages — the
  MSan-shaped bug class the ASan/UBSan gates can't see, surfaced by the
  EigenOS bare-metal port. Pairs with `MALLOC_PERTURB_` at suite time
  (documented on the target); zero cost when off. The full suite passes
  under poison + perturb.
- **#326 gap closed: member-assign statements enforce the terminator (#351).**
  The dot-/index-assignment statement paths missed the v0.23.0 check —
  `d.a is 2 3`, `l[0] is 8 9`, and `d.a += 5 6` still silently ran the
  trailing token as a second statement, and diverged from the
  meta-interpreter (which already gated these points, so `eigen_run`
  rejected what the C parser accepted). Both paths now call
  `p_end_statement`. Found during the ouroboros v0.23.0 pin bump; its
  frontend carries a `stmt_terminator_gap.eigs` canary that must be flipped
  (gap-exemption removed) at the next EIGS_REF bump. Regression: 4 checks
  added to section [113].

## [0.23.0] - 2026-07-01

### Performance
- **Compile time is linear in program size (#341).** Profiling (gprof, the
  12k-unique-name generated program) refuted the issue's suspect: 92% of
  compile time was `chunk_add_constant`'s linear dedup scan over the constant
  pool, with `name_set_add` (the filed suspect) second at 3% — and dominant
  only after the first fix. Both are now hash-indexed (open addressing;
  constant equality is byte-for-byte the old scan's tests, so pools stay
  identical — NaN still never dedups, -0.0 still merges with +0.0, and the
  AOT byte-parity contract is safe). The NameSet index also replaces the
  direct swap-removal at the param-filter sites with `name_set_remove`
  (rebuilds the index). Medians (n=5, N3350): 12k statements 8.76s → 0.07s
  (~125×); 3k/6k/12k now scale linearly (0.01/0.03/0.07s); 30k runs in 0.2s.

### Fixed
- **An out-of-range `OP_SET_LOCAL` is a runtime error (#348).** A slot ≥
  `env->count` silently DROPPED the write — the assigned variable simply
  never came into existence. Compiler-emitted writes are always backed (body
  locals size the call env; defaults-bearing chunks reserve their param
  slots), so the drop only hit hand-built bytecode (`vm_run_bytecode`
  descriptors, the ouroboros codegen): a defaults prologue on an underfed
  call wrote into a nonexistent slot and continued unbound (F-OURO-22;
  ouroboros pads a spare local as a workaround it can drop at the next pin
  bump). Now a catchable `SET_LOCAL slot N out of range` error.
  **`OP_GET_LOCAL`'s out-of-range null push stays, deliberately** — the fix
  originally made it an error too and 18 call-semantics checks failed: that
  null IS the "missing parameters bind to null" semantics for underfed calls
  to defaults-free functions (now documented at the handler). The JIT scan
  additionally refuses to compile local ops whose slot ≥
  `chunk->local_count` (the emitter reads/writes `env->values[slot]`
  unchecked — a violating JIT'd chunk was native out-of-bounds access, not
  even a silent drop); those ops interpret instead. Regression: 2 checks in
  `test_vm_run_bytecode.eigs` [93].
- **Constant pool past 65536 entries is a compile error, not a wrap (#341).**
  Constant indices are u16 operands; a pool crossing 65536 silently wrapped
  the emitted index, and a wrapped SET_NAME operand landing on a NUM constant
  made `const_interns[idx]` NULL — SEGV in `env_hash_name` (reachable since
  #327 removed the statement cap; found running the 100k-statement probe).
  The compiler now reports `constant pool exceeds 65536 entries in one chunk`
  once and aborts via the post-compile gate. Regression: section [114]
  (generated at test time). Widening to a 32-bit operand (`OP_CONST_WIDE`)
  is the future lift if a real consumer needs it.

### Documentation
- **GRAMMAR.md brought back in sync with the parser (#329, #330, #331, #332,
  #333).** It was frozen at "v0.8.0+" while the parser grew: added the four
  bitwise precedence levels (`|` `^` `&` `<<`/`>>` between comparison and
  addition) and unary `~`; compound assignment (`+=` family, incl. dot/index
  targets); slices; destructuring; index assignment; parameter defaults; the
  IDENT-rooted restriction on dot/index assignment targets (#332); the true
  postfix applicability matrix (#329: NUM/STR/list literals take subscripts
  only; f-strings and soft-keyword fallbacks take full postfix); the `of`
  precedence-table row corrected Left→Right (#333); the named-parameter
  "unpack" note replaced with the real literal-only spread rule; and the
  extended numeric-literal forms (#331: `.5`, `1.`, `1e5`, `0x10` via strtod)
  documented in both GRAMMAR.md and SPEC.md. The zero-parameter lambda's
  implicit `n` (#330) is now documented in SPEC.md as deliberate
  classic-style mirroring. Statement-terminator and break/continue rules
  cross-referenced (#326/#337).

### Fixed
- **The statement terminator is enforced (#326).** Every statement path ended
  in a tolerant `p_match(TOK_NEWLINE)`, so the NEWLINE in the documented
  grammar (`program = { statement NEWLINE }`) was never required — any
  leftover tokens on a line silently parsed as a *second* statement:
  `x is 2 x is 3` set x to 3, `y is 2 3` discarded the 3, and the typo'd
  `throw "boom"` (missing `of`) evaluated `throw` and `"boom"` as two
  discarded expressions — silently disabling error handling. A statement must
  now end at NEWLINE/EOF/DEDENT (`Parse error line N: unexpected X after
  statement — one statement per line`), with recovery to end-of-line so one
  bad line yields one diagnostic; `break`/`continue`/`import` enforce it too
  (`break 5` no longer runs `5` as a statement). The meta-interpreter's
  parser (`lib/eigen.eigs`) enforces the same rule at its eight simple-
  statement return points — accepting the shape there would be a silent
  over-acceptance divergence. GRAMMAR.md and SPEC.md already promised this
  ("a statement ends at the end of its line"); the implementation now
  matches. Known #315 (`1.2.3` silently splitting) is fixed as a side
  effect: the second half is now a parse error. Regression: section [113]
  (`test_stmt_terminator.eigs`) + `examples/errors/two_statements_one_line.eigs`
  gated by [90]. NOTE for ouroboros: `frontend.eigs` currently mirrors the
  old tolerant behavior and must land the same enforcement (tracked in
  ouroboros#57) or VM-vs-AOT acceptance diverges.
- **`break`/`continue` outside a loop are now compile errors (#337).** They
  compiled to silent no-ops (an explicit `OP_NULL`), so a mis-indented `break`
  left its loop spinning with no diagnostic — including inside a function body
  with no loop of its own (a break there never crosses frames to the caller's
  loop). Both now report `Compile error line N: 'break' outside a loop` and
  abort via the existing post-compile gate. The same gate is now enforced at
  every dynamic entry point: `eval`, `load_file`, and `import` previously
  checked `g_parse_errors` only after *parse*, so compile-stage diagnostics
  executed a placeholder chunk anyway — all three now fail with a catchable
  error. Module-level `return` (ends the program, value discarded, exit 0) is
  now documented in SPEC.md's Program model. Regression: section [112]
  (`test_stray_break.eigs`) + two new `examples/errors/` demos gated by [90].
- **f-string interpolation: whitespace and nested-string braces (#334).** Two
  lexer defects. (1) `f"{ x }"` (leading space) failed with "unexpected indent
  in expression": the interpolation body is re-lexed as a fresh source string
  and the splice loop dropped NEWLINE but not INDENT/DEDENT, so the leading
  space lexed as line-start indentation. All three layout tokens are now
  skipped. (2) The brace scanner counted `{`/`}` byte-wise, so a brace inside a
  *string literal within the interpolation* terminated the expression early
  (`f"{"a}b"}"` → unterminated-string errors). String literals are now copied
  wholesale (with escape handling); nested f-strings still balance via depth
  counting. Regression: 6 new checks in `test_fstrings.eigs` [21].
- **Soft-keyword identifier fallback now takes postfix (#328).** `prev`, `at`,
  and the six question words fall back to ordinary identifiers outside their
  special forms, but the fallback returned a bare IDENT with no postfix chain —
  `prev is [1,2]` then `prev[0]` was a parse-error cascade while `prev + 1`
  worked. All soft-keyword fallbacks now share the IDENT branch's postfix
  chain (`[i]`, `[a:b]`, `.key`) via a new `parse_postfix_chain` helper; the
  special forms (`prev of x`, `what is e`) still win. Regression: SK13-SK18 in
  `test_soft_keyword_idents.eigs`.
- **Meta-interpreter: silent wrong values eliminated (#338).** Two undocumented
  divergences in `lib/eigen.eigs` produced wrong results with no error on
  identical source. (1) The tokenizer's final branch *skipped* unknown
  characters, so unsupported operators silently mangled: `x += 2` lexed as a
  discarded `x + 2` (variable unchanged), `5 & 3` as two statements (`a is 5`),
  dot/index compound forms likewise. The tokenizer now **raises** a tokenize
  error on any character it can't lex (`\r` treated as whitespace); compound
  assignment and bitwise stay unimplemented but fail loudly. (2) `eigen_eval`'s
  call node spread *any runtime list* over multi-param functions; the C rule is
  literal-only (2+ elements, decided at the call-site AST; a variable list
  binds whole to the first parameter; missing parameters bind to null). The
  meta call node now checks the argument NODE and null-fills, matching the VM
  on all four shapes (literal spread / variable no-spread / 1-element literal /
  short-spread null-fill — each verified against the C VM). Header parity
  claims updated; loud parse gaps (slices, destructuring, param defaults,
  `<<`/`>>`) remain tracked as #339. Regression: 7 new checks in section [107]
  (`test_meta_parity.eigs`).
- **Parser statement cap removed (#327).** `parse()` and `parse_block` stored
  statements into fixed 4096-entry arrays and silently discarded everything
  past the cap — a 100k-statement program ran only its first 4096 statements
  and exited 0; a `define` body past the cap lost its tail *including its
  `return`* and yielded null. Both arrays now grow on demand (and no longer
  preallocate 32KB per block — 256-deep nesting used to reserve ~8MB up
  front). Exactly the wrong failure mode for generated programs (iLambdaAi).
  Regression: section [111] (`test_stmt_cap.eigs`) — a 4200-statement program
  and a 4200-statement function body run in full. Note: removing the cap
  exposes a pre-existing quadratic compile cost on programs with tens of
  thousands of *unique* module-scope names (NameSet linear-scan dedup) —
  tracked separately; normal programs are unaffected.
- **Compiler loop-context caps removed (#335, #336).** Two fixed-size arrays in
  the compiler silently degraded on big/deep loops. (1) `MAX_BREAK_JUMPS` (64):
  break #65+ in one loop emitted its `OP_LOOP_ENV_END` cleanup but *dropped the
  jump* — execution fell through into the rest of the iteration with the loop
  env already torn down, and the loop's natural exit freed it again (runtime
  `double free or corruption`, SIGABRT, on well-formed source). (2)
  `MAX_LOOP_DEPTH` (32): loops nested deeper pushed no `LoopCtx`, so a `break`
  inside loop 33+ registered with the **32nd** loop's context and got patched to
  its exit — wrong jump target plus unpopped iterator state corrupting outer
  iterations, rc=0. Both are now dynamic: the loop stack is a grown array of
  heap-allocated contexts (pointers, so an outer loop's ctx can't dangle when a
  nested loop grows the stack) and `break_jumps` grows per context; everything
  frees when the outermost loop pops, so no compiler-teardown changes. A break's
  env cleanup and its jump are now emitted unconditionally as a pair.
  Regression: section [110] (`test_loop_caps.eigs`) — the 65th break executing
  in a for-loop and a while-loop, and a break inside a 33-deep nest exiting
  exactly one loop. Found in an adversarial language review.
- **`throw` now halts the caller's remaining statements (#322).** A `throw` that
  propagated out of a *called* function did not stop the **calling** function
  from running its subsequent statements — execution (including side-effecting
  builtin calls) continued until the nearest enclosing `try`, or the function
  returned. `CHECK_ERROR` (the per-instruction error hook) only caught in the
  *throwing* frame or halted when no handler existed anywhere; when a handler
  existed only in an **outer** frame it fell through and kept executing the
  current frame. Fix: `CHECK_ERROR` is now a loop that, for that missing case,
  unwinds the current frame (drains its stack window, frees an owned env,
  restores its loop-stall globals, drops its chunk ref — mirroring the uncaught
  `vm_error_halt` per-frame drain) and re-checks at the caller, repeating until
  it reaches the handler frame (catch) or runs out (halt). The control case
  (throw directly in a `try` body) and the uncaught case were already correct
  and are unchanged; a callee that catches its own error still doesn't
  over-unwind. Since `DISPATCH` runs `CHECK_ERROR` before every instruction, the
  fix covers the whole interpreter; JIT-hot throwing chains bail to the
  interpreter and propagate correctly too. Regression: section [109]
  (`test_throw_unwind`) — multi-level nesting, throw-in-a-loop-in-a-function,
  inner-catch (no over-unwind), and a JIT-hot chain. Surfaced while fixing #306.
- **`sandbox_run` allocation budget (#292).** The sandbox bounded loop back-edges
  and the builtin surface but imposed no *memory* budget: an allowlisted allocator
  (`zeros`/`fill`/`buffer`/`range`) could exhaust RAM in one capped-but-large call,
  or aggregate across a loop (each iteration's allocation never trips the
  back-edge counter), and the resulting out-of-memory went through `x_oom →
  abort()` — **uncatchable** by the sandbox's `g_has_error` path, so the host
  process died with SIGABRT (a generated `zeros of [99999, 99999]` was enough).
  Added a per-run byte budget: the size-controlled allocators call
  `sandbox_charge()` before allocating, and a charge that would exceed the budget
  raises a *caught* error so `sandbox_run` returns `{ok:0}` instead of aborting.
  The budget is cumulative over the run (so the aggregate-in-a-loop vector is
  bounded too) and configurable via a new optional `max_bytes` arg
  (`sandbox_run of [descriptor, max_iterations?, max_bytes?]`, default 256 MiB).
  Also gave `zeros` the same per-call size cap `fill`/`buffer` already had (it was
  uncapped, so it could `abort()` even outside a sandbox). Regression: section
  [108] (`test_sandbox_budget`), including the cumulative case. The in-process
  budget covers the array/tensor allocation vectors; a fork+`setrlimit` jail would
  cover every byte but would have to serialize the result Value across the pipe
  (breaking the `{ok, result}` contract existing callers read) and can't safely
  fork a pthreads process — out of scope here.
- **Meta-interpreter parity with the C evaluator (#306).** `lib/eigen.eigs`
  advertised "full parity" but `eigen_eval` diverged from the C VM: `and`/`or`
  returned `0`/`1` instead of the deciding operand (so `1 and 2`→`1` not `2`,
  `0 or 3`→`1` not `3`, breaking the `x is config or fallback` idiom), and an
  unbound identifier silently returned `null` instead of raising. Fixed: `and`/
  `or` now do value-returning short-circuit using the host VM's own truthiness
  (exact falsy-set parity: `0`, `""`, `null`, empty list/dict), and an unbound
  name raises via a new `_env_has` existence check (distinct from a name bound
  to `null`, which still returns `null`). The divide/modulo-by-zero *value* was
  already at parity (`0`); the C VM's stderr `Warning ... division by zero` can't
  be emitted (EigenScript has no stderr-write builtin) and error messages carry
  no `line N` prefix (eval-time AST nodes don't track lines) — both now
  documented in the header instead of over-claimed. ouroboros is unaffected (it
  vendors only the front-end, not `eigen_eval`). Regression: section [107]
  (`test_meta_parity`). Surfaced a separate, pre-existing host bug — a `throw`
  inside a function body doesn't halt the caller's subsequent statements — which
  is tracked on its own, not in this fix.
- **Cycle collector now reclaims local pure-value cycles (#307).** A list/dict
  that referenced itself (or a peer that pointed back) and was built inside a
  function then dropped was reclaimed by *nothing*: the runtime collector built
  its universe only from the captured-env registry (closure cycles), and the
  exit collector only from a global-scope snapshot — so a purely-local value
  cycle leaked, unbounded, for the life of the process (ASan: a 50k-iteration
  self-ref-list loop leaked 6.8 MB / 100k objects; mutual dicts, 26 MB). Most
  damaging for long-running consumers (graph/tree structures with back-edges)
  and the freestanding/EigenOS target, where there is no process exit to mop up.
  Fix: a Bacon-Rajan "possible root" hook (`gc_note_possible_root`) — when a
  LIST/DICT loses a ref but stays alive, it is parked (with one pin) on a
  per-state value-candidate buffer; `gc_collect_cycles` feeds that buffer into
  the existing mark-sweep as pinned seeds (the pin is accounted exactly like the
  exit snapshot's, so a cycle held only by its pin + internal edges still counts
  as garbage), then drains the pins. Hooked into both `val_decref` and
  `slot_decref` (the env-slot drop is the dominant path by which a function-local
  cycle dies), gated like the env registry (off when GC-disabled, mid-collection,
  or multithreaded — kept off the lock-free hot decref). No semantics change; the
  collector's edge-accounting and the strictly-leak-clean closure-cycle gate
  ([87]) are untouched. Regression: section [106] (`test_value_cycles` — self-,
  mutual-, and back-edge value cycles reclaimed; a live globally-rooted cycle
  survives the churn), strict leak-gated like [87]. ~1–2% on a container-heavy
  bench (within box noise; the decref-to-zero path is unchanged).

## [0.22.0] - 2026-06-29

### Fixed
- **Data races: parallel workers executing the same shared chunk (#297).**
  ThreadSanitizer flagged ~22 races when concurrent `spawn`'d workers ran the
  same chunks: the refcount-mode gate (`g_vm_multithreaded`) was re-written on
  *every* spawn, racing already-running workers reading it in
  `env_incref`/`chunk_incref` (the correctness-critical ones — a lost flag read
  could take the non-atomic refcount path → UAF); the per-chunk JIT hotness
  counters (`exec_count`/`back_edge_count`) and OSR machinery; the env/dict
  inline caches (a torn write risks a wrong cache hit when two threads share an
  env); the lazy name-hash cache (`const_hashes[idx]`); and `g_trace_current_line`.
  Fixes: write the multithreaded flag only on the 0→1 transition (it's published
  to all workers via the first write's happens-before); gate the JIT counters,
  OSR, inline-cache *writes*, and the trace-line store off under MT (JIT compile
  is already MT-gated by #296; the IC fast-path *read* stays — it just misses for
  a worker's env); and precompute the name hash at compile time instead of
  lazily at runtime (eager, idempotent, a tiny perf win). Single-threaded
  behavior is unchanged (every gate passes when not multithreaded). Result:
  ThreadSanitizer reports **0 data races** on a parallel-shared-closure workload
  (was ~22). Regression: section [102] (`test_spawn_parallel` — 12 concurrent
  workers, exact results). Suites 2340/2340, leak floor 0, jit-smoke green.
- **Threaded cycle-GC: env↔closure cycles created on worker threads now collected.**
  The cycle collector's candidate registry was per-thread and was emptied +
  disabled the moment `spawn` went multithreaded, so any env↔closure cycle
  created after the first spawn — on the main thread or a worker — was never a
  collection candidate and leaked at exit (e.g. `test_concurrent` leaked ~21 KB).
  Moved the registry to the EigsState (shared across the state's threads),
  guarded by a `gc_lock` taken only while multithreaded; registration now
  continues across threads, while collection still runs only single-threaded
  (it races mutators otherwise). `handle_table_drain` clears `multithreaded`
  after joining every worker, so the exit-time `gc_collect_at_exit` sweeps the
  whole accumulated registry — reclaiming both main-thread and (since-joined)
  worker-thread cycles. Verified race-free with ThreadSanitizer (no races on the
  registry; the lock synchronizes concurrent register/unregister); the cycle
  collector's strict-clean section [87] still passes. Regression: section [101]
  (`test_spawn_gc`, leak-gated). Prerequisite was #296 (the apparent "GC change
  crashes" was actually the worker-JIT UAF). NOTE: parallel workers executing the
  *same* shared chunk still race on per-chunk advisory state (exec_count, JIT
  hotness counters, inline caches, shared-env refcounts) — pre-existing, separate
  from this change; tracked separately.
- **SEGV: shared chunk JIT-compiled on a worker thread (#296).** A function that
  got hot and JIT-compiled while running on a `spawn`'d worker left
  `chunk->jit_code` pointing into that worker's *per-thread* JIT code arena,
  which `jit_thread_destroy` munmaps at thread detach. `chunk->jit_code` is a
  single pointer on the *shared* chunk, so the next caller jumped into freed
  executable memory → SEGV (reliably at scale, e.g. a worker that calls a shared
  helper in a loop, repeated across ~50+ workers; pre-existing, layout-sensitive
  UAF). Fixed by gating JIT compilation off while multithreaded
  (`jit_try_compile_chunk` / `_osr` no-op under MT, leaving `jit_state` at 0 so
  compilation resumes once single-threaded) — matching the existing "disable
  while MT" policy for the cycle collector and call-env parking. Code main
  compiled outside the MT window lives in main's arena (alive until exit) and is
  safe to run from a worker. Regression: suite section [100] (`test_spawn_jit`,
  leak-clean, reproduces the SEGV with the gate removed).
- **Spawn/channel memory leaks at exit — ASan "tolerated leak" floor 4 → 0.**
  Two fixes, both most relevant to the freestanding/EigenOS target where there
  is no process exit to reclaim resources:
  - *Handle-table resources never reclaimed.* Channels (`channel of …`) and
    spawned-thread handles live in the process handle table keyed by an integer
    id, not on a refcounted Value, so the GC never freed them — `close_channel`
    only flips a flag, and an unjoined worker left its `ThreadHandle` behind.
    Added `handle_table_drain`, run once the program finishes (value world still
    alive): joins any still-registered worker (`spawn` uses a joinable pthread;
    `thread_join` already frees joined ones, so no double-join), then frees every
    remaining channel (drains+decrefs buffered messages, destroys the mutex/conds,
    frees the struct).
  - *Worker return value over-incref'd.* `thread_entry` did `val_incref` on the
    result, but `vm_execute` already returns an owned ref that the handle takes
    over — a second ref with no owner that leaked the worker's return value
    (masked when the return happened to be arena-allocated). Removed.
  Together these clear every `rc_ok`-gated spawn/channel test. One residual
  remains and is *not* in the tally: `test_concurrent` leaks ~21 KB of
  main-thread env↔closure cycles created after the first `spawn` —
  `env_mark_captured` skips GC registration while multithreaded (cross-thread
  registry hazard), so they're never collection candidates; its [55] suite block
  is marker-only so doesn't gate on it. Reclaiming it needs a thread-safe GC
  registry (threading hardening). A spawn+join loop does *not* accumulate
  (verified to N=400).

### Added
- **`report_value of x` — a value-signal observer channel (#294).** The
  windowed observer predicates (`report`/`converged`/`stable`/`oscillating`)
  classify the trajectory of `entropy(value)`, not the value itself. Because
  entropy is a non-monotonic projection of `|x|` (flat in mid-magnitude
  regions), a sustained *value* oscillation there reads as `stable` — the
  observer faithfully measures entropy-settling, which is a lossy proxy for
  value-settling. Proven against a closed-form oracle `x = 5 + 0.6·cos(k·ω)`
  (oscillates forever): `report of x` says `stable` in the flat-entropy
  plateau, while the new `report_value of x` says `moving`/`oscillating`
  uniformly — never falsely `converged`. The new form runs the *same* windowed
  logic and thresholds on the value's relative step `Δv/(1+|x|)` (relative, so
  bands carry the same meaning across value scales); vocabulary
  `oscillating`/`converged`/`stable`/`moving`/`equilibrium`. Purely additive: a
  parallel per-slot value window beside the entropy window, two new appended
  opcodes (`OP_REPORT_VALUE_SLOT`/`_NAME`), and a compile-time intercept
  paralleling `report`. Existing entropy predicates are unchanged. See
  docs/OBSERVER.md ("Two signals").

## [0.21.2] - 2026-06-29

### Fixed
- **Cross-thread channel transfer corrupted dict string keys (#293).** Values
  sent on a channel were shared by reference (incref'd, not copied). A dict's
  string keys are interned in the *creating thread's* per-thread intern table,
  which is freed when that thread detaches — so a dict built in a worker, sent
  over a channel, and read after the worker exited had dangling (garbage) keys
  (`msg.k` read null; surfaced by EigenGauntlet's `concurrent` lab as
  `cannot apply '+' to num and null`). `send` now deep-copies the value
  (`val_clone_for_send`), re-homing dict keys into a process-global, deduped,
  lock-protected intern table that lives for the process (reachable root → not
  a leak). String *values* were already owned and unaffected; fn/builtin/buffer
  are still shared by refcount. The copy also removes the old
  shared-mutable-container concurrency footgun for the copied types. Regression
  test: suite section [98] (cross-thread dict built in a spawned worker).

## [0.21.1] - 2026-06-29

### Fixed
- **JIT/OSR use-after-free on a re-entrant env realloc (#291).** A function
  whose `local_count` sat at the env capacity boundary would realloc
  `env->values` mid-body when the loop machinery bound its two implicit names
  (`__loop_iterations__`, `__loop_exit__`) — which `env_reserve_slots` did not
  account for. That realloc freed the array the JIT's `%r12` (`fn_env->values`)
  cache pointed at; a re-entrant `vm_execute` (`sandbox_run`/`vm_run_bytecode`)
  then reused the freed memory, so the next inline `GET_LOCAL` read garbage and
  threw `cannot index num` (intermittently, JIT-only). Surfaced by iLambdaAi's
  `grade()` ladder running its OSR-hot `ids_to_text` decoder interleaved with
  `sandbox_run`. Fix: `env_reserve_slots` now reserves `ENV_LOOP_BIND_HEADROOM`
  (2) extra *capacity* for the implicit loop bindings, so a call-time-reserved
  env never reallocs mid-body. Full suite + ASan leak-tally unchanged.

## [0.21.0] - 2026-06-28

### Security
- **`sandbox_run` is now fail-closed (allowlist).** The sandbox previously
  shadowed a hand-maintained *blocklist* (`SANDBOX_DENY`) — fail-open, so every
  builtin was reachable unless someone remembered to deny it. Builtins nobody
  had flagged leaked: `set_observer_thresholds` let sandboxed code rewrite the
  **process-global** observer thresholds (corrupting observer behavior for the
  whole host — including iLambdaAi's own `grade()` — after the run returned);
  the `screen_*` terminal ops, channel ops, and `exit` (which would kill the
  host) were also reachable. Replaced with a pure-compute **allowlist**
  (`SANDBOX_ALLOW`): the sandbox env shadows every global name not on the list,
  so a new builtin is denied by default and a gap costs only functionality,
  never host safety. The http_/db_/model_ extension surface is now auto-denied
  without enumeration.
- **HTTP aggregate request-body DoS.** The HTTP server bounded each request
  body (`EIGS_HTTP_MAX_BODY`, 16 MiB) and concurrent connections
  (`HTTP_MAX_CONCURRENT_CONNS`, 256) independently, but their *product*
  (~4 GiB held at once) was unbounded against host memory — a flood of
  concurrent max-size uploads could OOM the host even though no single request
  or connection misbehaved. Added a global in-flight body-byte budget
  (`EIGS_HTTP_MAX_BODY_TOTAL`, default 128 MiB): a connection whose buffer
  growth would push the aggregate past the budget is shed with `503`. Charged
  during the read loop and released on every connection exit path.
- **`sandbox_run` could be hung by a blocking builtin.** The iteration cap
  (`g_sandbox_loop_max`) bounds loop back-edges, not time spent inside one
  builtin, so a blocking builtin missing from the deny list hung the host
  indefinitely (e.g. `usleep of 30000000`, or `recv` on a channel that — spawn
  being denied — can never receive). `usleep`, `raw_key`, `recv`, `try_recv`,
  `recv_timeout`, and `send` are now shadowed by the blocked stub in a sandbox
  run, matching the file/process/network/db/thread builtins already denied. This
  matters most for the untrusted, *generated* code `sandbox_run` exists to grade.

### Fixed
- **Observer state drift across parked call-env reuse.** `vm_park_call_env`
  recycles a function's call env in place (the per-chunk `env_cache` fast path),
  but only reset the value slots — it left `Env::obs` (per-slot entropy/dH)
  intact. Observer state is part of binding identity (the #262 Phase-1 invariant
  resets it "on both park and free"; `env_free` honored it, this newer fast-park
  path silently did not), so a windowed predicate (`converged`/`stable`/…) on an
  observed **local** read the *previous* invocation's trajectory — a function
  with fewer than the window's worth of observed assignments would falsely
  "converge" on its second call. Now resets observer state on park. Caught only
  by an observer-output differential (park-on vs park-off).

### Restored
- **`exit` builtin** — `exit of N` performs a clean, uncatchable process exit
  with code N, unwinding to main's teardown via `g_has_error` (leak-clean even
  with live closures) rather than a raw `exit()`. Dropped in 0.19.0; consumers
  (tidelog/liferaft) use it on failure paths.

## [0.20.0] - 2026-06-28

### Added

- **Named observer predicates: `<predicate> of <var>`.** Each of the six
  predicates (`converged`, `stable`, `improving`, `oscillating`, `diverging`,
  `equilibrium`) now accepts a named operand — `converged of x` — that
  classifies *that binding's* slot trajectory, parallel to `report of x`. The
  bare form (`converged`) is unchanged: it reads the **last-observed** binding
  in scope, which a trailing assignment silently repoints (every assignment is
  observed) — e.g. a `loop while not converged` whose body increments a counter
  after the iterate halts on the counter, not the iterate (this is why
  `dynamics`' `settle_steps` returned the same step count for every rate). The
  named form removes the ambiguity, and a named-predicate loop condition
  (`loop while not (converged of x)`) is self-terminating — it reads x's slot
  each iteration and does not arm the global-alias auto-stall the bare form
  opts into. Prefer the named form whenever more than one binding is observed
  in scope. Adds opcodes `OP_PREDICATE_SLOT` / `OP_PREDICATE_NAME` (appended at
  the end of the enum). See docs/PREDICATES.md.
- **Linter warning `W014`** flags a bare predicate in a loop condition whose
  body assigns more than one binding (where the last-observed binding — and so
  which one the predicate reads — is order-dependent). The named form
  `<predicate> of <var>` silences it; a single-observe loop body is not flagged.

### Performance

- **`for`-loops now reuse one loop env instead of allocating a fresh one per
  iteration.** A `for` that still needs a per-iteration env (notably every
  module-scope loop, where the loop var and loop-locals must not leak) used to
  `env_new`/`env_decref` every pass, which also thrashed the name-resolution
  inline cache for outer variables read in the body. The env is now created
  once and reused, in three tiers gated entirely at compile time:
  loops whose body defines a closure keep the old fresh-per-iteration behavior
  (the closure captures the env, so it can't be reused); loops with a
  loop-local or shadow persist the env and `LOOP_ENV_CLEAR` it each iteration
  (saving the allocation); and loops that provably create no loop-local
  (every assignment is an outer mutation) persist *and overwrite* the loop var
  in place with no clear, so `binding_version` stays stable and the outer-var
  inline cache stays hot. On a 2M-iteration accumulator this is ~30–36% faster
  (observed and unobserved alike); semantics are unchanged — the overwrite
  tier's loop-local proof is conservative and any uncertainty falls back to
  clear, then to fresh. Adds opcode `OP_LOOP_ENV_CLEAR` (appended at the end of
  the enum; `LOOP_ENV_CLEAR` also resets the env's slot-keyed observer state so
  an observed loop-local matches fresh-env `report`/predicate behavior).

### Fixed

- **Memory-unsafe crashers on adversarial input (security).** A re-review of the
  runtime closed ten reachable crashes and a leak, all triggerable from pure
  EigenScript or hand-assembled bytecode: parser C-stack overflow on deeply
  nested prefix (`not`/`-`/`~`) and right-recursive `of` expressions and on long
  iterative postfix/binop chains (`a[0][0]…`, `1+1+…`) that bypassed the
  parse-depth guard and overflowed the recursive compiler; integer-overflow
  heap corruption in `str_replace`, `buf_copy`, `matmul` (incl. the flat-buffer
  fast path) and a `substr` over-allocation; the `sandbox_run` / `vm_run_bytecode`
  bytecode bridge, which trusted operand indices — a hand-built descriptor with
  an out-of-range constant / function / jump operand, a name operand pointing at
  a non-string constant, or an `OP_DICT` count larger than the live stack drove
  an out-of-bounds read past the name deny-list and loop cap (now a one-pass
  bytecode verifier rejects such a chunk before it runs); an un-encodable
  (>64 KB) jump/loop offset that silently left a wild jump; and a JIT `and`/`or`
  per-iteration reference leak (the PEEK ops were wrongly marked as pushing an
  immediate, so the fall-through `OP_POP` skipped the decref of a heap left
  operand once OSR-compiled). Malformed source and untrusted assembled bytecode
  no longer crash. (PRs #277, #278.)
- **Temporal queries were wrong under the JIT/OSR.** The JIT's `OP_LINE` updated
  `g_vm.current_line` but not `g_trace_current_line` (the line the history tape
  records), so once a loop OSR-compiled, every `what/when/where/why/how is x at
  <line>`, `state_at`, and named interrogative read the line frozen at the point
  the thunk took over — e.g. `4999` instead of `19999` in a 20000-iteration
  loop. The interpreter and `prev of` were unaffected. The OP_LINE arm now
  stamps both, mirroring the interpreter. (PR #279.)
- **HTTP routes ignored a request's query string for route identity.** The
  request target was parsed whole into `path` (`ext_http.c`), so a route
  registered as `/ping` returned 404 for `/ping?x=1` — both exact route
  matching (`strcmp(r->path, path)`) and static-file serving compared against
  the raw target including `?...`. The query string is request data, not part
  of the route, so the target is now split at the first `?` before route and
  static matching. The original request line stays intact in
  `http_request_headers` (raw `reqbuf`), so scripts can still read the query
  via `lib/http.eigs`'s `parse_query`. Covered by `test_http_server.sh` HS01b
  (route + query) and HS05b (static file + query).
- **LSP rename is now scope-correct, including EigenScript's subtler rules.**
  Rename resolves each occurrence to a binding identity — the innermost
  enclosing function that binds the name as a parameter or `local`, else the
  global — and only renames occurrences sharing the cursor's binding. This
  covers (a) explicit parameter shadowing, (b) the **implicit `n`** parameter
  of a no-arg `define` (a real whole-body binding, so a body `n` is not the
  global `n`; issue #241), (c) **order-sensitive `local`** — a `local x` binds
  only from its declaration onward, so a read *before* it resolves to the outer
  binding, and (d) **`for`-loop scopes** — a statement `for` introduces a scope
  for its loop variable and any `local` inside it (neither leaks out;
  SS5E/SS5F/SS8) — but a `for`'s **iterable expression** (between `in` and the
  body) is evaluated in the outer scope, so in `for i in i:` the second `i` is
  the outer binding, not the loop variable. A **default-parameter expression**
  (`define f(b is a)`) is likewise evaluated in the outer scope — only the name
  before each `is` is a parameter, so the default's identifiers resolve to
  their real binding (an outer var, or an earlier param if named). `if`, `loop
  while`, and comprehensions are transparent (their loop-vars/locals touch the
  surrounding scope, matching the runtime). Positions still come from exact
  token spans.
  Verified by applying the WorkspaceEdit and asserting the resulting source for
  each rule.
- **LSP rename could corrupt source.** Reference positions came from AST node
  columns, but identifier (`AST_IDENT`) nodes were built with `make_node`,
  which zero-fills `col` — so every rename edit landed at column 0. Renaming
  `count` returned edits at `[line,0]`, missing the real occurrences and
  overwriting the start of unrelated lines (e.g. replacing `print`). Fixed at
  the root: the five `AST_IDENT` sites now carry the identifier token's real
  line/col. Rename itself was additionally rewritten to take every edit
  position from the **token stream** (always-exact spans), skipping
  dot-member accesses (`obj.name`) — so it can no longer mis-place an edit
  regardless of AST-node quirks. This also fixed function rename (its
  definition came from a symbol with a stale position) and parameter rename.
- **`find_token_at` let an adjacent token steal the cursor position.** Its
  hit-test used `col < t->col + len + 1` (a one-column slop), so `(` at the
  column before a parameter claimed the parameter's column — rename/hover from
  a signature returned the wrong token (or nothing). Now uses strict
  containment `[col, col+len)` with a closest-token fallback.
- **LSP leaked an AST on every document change.** `doc_analyze` set
  `doc->ast = NULL` without freeing the prior parse; a long editing session
  leaked one AST per `didChange`. Now frees it (and on `didClose`). AST nodes
  own their strings, so this is safe after the token list is freed.
- **Assignment statements were tagged with the *next* line.** The parser
  built an `AST_ASSIGN` node for `name is expr` after consuming the
  statement's trailing newline, so it took the following line's number —
  offsetting every assignment by one for the linter, LSP go-to-definition,
  document symbols, and diagnostics. Now taken from the name token. Surfaced
  by wiring lint diagnostics into the LSP (the squiggle landed a line low).

### Added

- **LSP: semantic tokens**, plus a `len` (source-span) field on every token.
  `textDocument/semanticTokens/full` classifies the token stream — keywords,
  numbers, strings, and (the part a TextMate grammar can't do) identifiers as
  function / variable / parameter / namespace via the symbol table — and emits
  the LSP delta-encoded array. The new `Token.len` (set in the lexer, exact for
  every lexeme) also replaces `find_token_at`'s old "number length ≈ 4" guess,
  tightening hover/definition hit-testing.
- **LSP: lint diagnostics + code actions.** With a document that parses, the
  server now runs the linter and publishes each warning as a coded diagnostic
  (severity 2, `code` = the #3 W-series), so the editor shows the same issues
  as `--lint` — not just the first parse error (which now also carries
  `code: E002`). `textDocument/codeAction` offers a quickfix for `W001`
  (remove the unused-variable line); the handler recomputes diagnostics from
  the AST and is structured to take more code→fix mappings. `lint.c` grew a
  reusable `lint_collect(ast, …)` core (no I/O) shared by `--lint` and the LSP.
- **LSP: document symbols, workspace symbols, formatting, and rename.** The
  language server (`src/eigenlsp`) now advertises and handles
  `textDocument/documentSymbol` (outline of functions, imports, and top-level
  variables), `workspace/symbol` (case-insensitive filter across open
  documents), `textDocument/formatting` (a whole-document edit produced by the
  CLI formatter — `fmt.c` grew a reusable `format_source_string` string→string
  core shared by `--fmt` and the LSP), and `textDocument/rename` (a
  WorkspaceEdit over every reference plus the definition; refuses to rename
  builtins/keywords). Builds on the existing symbol table and reference walker.
  `tests/test_lsp.py` +13 behavioral checks. (Semantic tokens and code actions
  remain — the former needs per-token source spans in the lexer, the latter is
  best wired to the linter's coded diagnostics.)
- **First-class test runner — `eigenscript --test [paths...]`.** Discovers
  `test_*.eigs` files (in `./tests` by default, or in given dirs/files) and
  runs each in its **own interpreter process**, so the `lib/test.eigs`
  assertion counters never bleed between files. A file passes iff it exits 0
  (the `test_summary` convention, which `assert`s on failure); the runner
  parses each file's `Tests: N | Pass: P | Fail: F` line to aggregate
  assertion counts, prints a per-file PASS/FAIL summary (showing a failing
  file's captured output), and exits nonzero if any file failed. `--json`
  emits a machine-readable result object for CI. The runner itself is written
  in EigenScript (`lib/test_runner.eigs`), dispatched like `--pkg`.
- **`exe_path of null` builtin** — returns the absolute path of the running
  interpreter binary (via `/proc/self/exe`, with an `argv[0]` fallback). Lets
  a script re-invoke the same interpreter without assuming `eigenscript` is on
  `PATH`; the test runner uses it to launch each test file. Surfaced by
  building `--test` — an EigenScript program previously had no way to find its
  own interpreter.

## [0.19.0] - 2026-06-26

### Added

- **Flat-buffer tensors (shaped `VAL_BUFFER`)** — a buffer now carries an
  optional 2-D shape: `buffer of [rows, cols]` makes a flat `double[rows*cols]`
  with that shape, and `reshape of [buf, rows, cols]` shapes an existing flat
  buffer (element count must match). `shape of <buffer>` returns `[rows, cols]`
  (or `[count]` when unshaped). The tensor builtins `matmul`/`add`/`relu` gain a
  shaped-buffer fast path that computes directly on the flat `double[]` — no
  per-call flatten/rebuild of nested lists — using the **same** kernels
  (`ne_matmul_buf` i-k-j accumulation, `num_guard` elementwise), so results are
  **byte-identical** to the nested-list tensor path. This eliminates the dominant
  cost of nested-list neural inference (re-flattening constant weights every
  call): a 3-layer MLP forward (433→64→32→6) is **~11× faster** with shaped-buffer
  weights, the forward source unchanged. 1-D buffers (`rows==0`) are treated as
  row vectors, so `matmul of [vec, mat]` yields a 1-D result. Back-compatible:
  `buffer of N` and flat `b[k]` indexing are unchanged (shape is metadata read
  only by the tensor ops).

- **`norm` reduction builtin** — `norm of a` returns the L2 (Euclidean) norm
  `sqrt(sum_i a[i]*a[i])` of a buffer or tensor. Like `sum`/`dot` its summation
  association is unspecified (opt-in SIMD reassociation); no-NaN/Inf preserved.

### Fixed

- **`sum` now works on buffers** — `sum of <buffer>` previously returned 0 (the
  tensor flatten path only walked lists, silently skipping the `VAL_BUFFER`
  numeric fast-path type). It now sums buffer elements directly. `sum`/`norm`
  also apply `num_guard` per step (no-NaN/Inf invariant), and their summation
  association is now documented as unspecified (see docs/SPEC.md "Reductions").

### Added

- **`dot` reduction builtin** — `dot of [a, b]` returns the sum over `i` of
  `a[i] * b[i]` for two numeric buffers (length = the shorter of the two).
  Its summation **association is unspecified by spec**: callers must not depend
  on the exact low-bit rounding. This is a deliberate opt-in that licenses an
  optimizing backend (the AOT native compiler) to reassociate the sum across
  SIMD lanes — a speedup a strict left-to-right `loop while` accumulation
  forbids, because FP addition is non-associative. The no-NaN/no-Inf invariant
  still holds (`num_guard` at each step). See docs/SPEC.md "Reductions".

## [0.18.0] — 2026-06-25

### Added

- **Streaming audio file playback (`audio_music_*`)** in the graphics
  extension (`src/ext_gfx.c`), so a program can play a real music file
  instead of only synthesized PCM samples. `audio_music_play of [path, loops]`
  streams an mp3/ogg/wav via SDL_mixer (`loops` -1 = forever); `audio_music_volume
  of v` (0–128) and `audio_music_stop of null` control it. Music plays on its
  own audio device alongside the existing SFX sample queue (two SDL audio
  devices coexist; the OS mixes them), so SFX are unaffected. SDL_mixer (and
  its MP3 codec, libmpg123) is `dlopen`ed lazily — same pattern as SDL2 — so
  the gfx binary keeps no hard link dependency and the headless build is
  untouched. Surfaced by Tidepool needing background music (its audio was
  sample-queue only). Build with `make gfx`; requires `libsdl2-mixer-2.0-0` at
  runtime.

## [0.17.2] — 2026-06-25

### Fixed

- **`spawn` now raises if the OS cannot create the thread** instead of
  silently returning a live-looking handle for a thread that never ran (#269).
  The
  `pthread_create` return value was ignored, so under memory pressure (where
  the new thread's stack allocation fails with `EAGAIN`/`ENOMEM`) the spawned
  function simply never executed — and any sibling that depended on it ran on:
  e.g. a thread meant to `close_channel` a channel another thread is waiting
  on never closes it, so the waiter blocks until its timeout, which for a
  large `recv_timeout` deadline is effectively forever. Surfaced as an
  intermittent hang of `tests/test_channel_nb.eigs` under the ASan suite on a
  4 GB host (ASan's overhead exhausted committable memory at thread-stack
  allocation). `spawn` now cleans up the unstarted handle and raises
  `spawn: could not create thread: <reason>`, turning a far-away hang into an
  immediate, clear error at the spawn point.
- **JIT/OSR: an on-stack-replacement thunk no longer over-reaches past its
  own loop's back-edge into enclosing-loop code** (#267). An OSR thunk is
  invoked at a hot loop header with the live stack pointer to accelerate that
  loop body; the scanner, however, kept walking past the loop's own back-edge
  into the post-loop continuation. For an *inner* loop that continuation is
  the *enclosing* loop's body, compiled against the enclosing loop's stack
  frame — but the thunk had entered mid-nest at the inner header, so running
  that code natively read the wrong (reserved-null / stale) stack slots and
  corrupted execution. It surfaced only under forced OSR
  (`EIGS_JIT_OSR_THRESHOLD=1`) on nested-loop, index-heavy programs (e.g. the
  dynamics lab's Gauss–Seidel solver) as a nondeterministic `cannot index
  num` (a null `INDEX_GET` target), `index must be an integer`, or double
  free; ASan was clean because the corruption stayed within the VM stack
  bounds. The OSR prefix scanner now stops right after a loop's own back-edge
  (`JUMP_BACK` whose target equals the OSR entry offset), confining each OSR
  thunk to its hot loop body — which is the correct OSR boundary anyway, so
  every nested loop now gets its own tight thunk instead of one over-reaching
  inner thunk. The from-zero compile (entry offset 0) is unchanged: it enters
  at the function start where the stack frame matches the compiler's tracking.

## [0.17.1] — 2026-06-25

### Fixed

- The prebuilt **Linux release binary is now built on Ubuntu 22.04** (glibc
  2.35) instead of `ubuntu-latest`. GitHub moved the `ubuntu-latest` runner
  from 22.04 to 24.04 (glibc 2.39), which raised the v0.17.0
  `eigenscript-linux-x86_64` binary's glibc floor to `GLIBC_2.38` — so it
  failed with `GLIBC_2.38 not found` on Ubuntu 22.04 LTS (a current,
  widely-deployed LTS). Building on 22.04 keeps the floor at glibc 2.35, so the
  binary runs on 22.04 and every newer distro. Homebrew and source builds were
  never affected (they compile against the local libc).

## [0.17.0] — 2026-06-25

### Added

- Stdlib gap-fill across `lib/list.eigs`, `lib/string.eigs`, and
  `lib/math.eigs` — all pure EigenScript, no C:
  - `list`: `any`/`all` (short-circuit predicate checks), `find_index`
    (first index where a predicate holds, `-1` if none), `partition`
    (`[passing, failing]` in one pass), `group_by` (bucket into a dict by a
    stringified key), `deep_flatten` (full recursive flatten),
    `count_of`/`frequencies` (occurrence count / full distribution dict).
  - `string`: `capitalize` (uppercase the first character),
    `replace_all` (replace every occurrence; non-overlapping, no
    re-replacement of inserted text; empty `find` returns the source
    unchanged).
  - `math`: `argmax`/`argmin` (index of the largest/smallest element,
    first index on ties, `-1` if empty).
  - Closes the stdlib good-first-issue set (#181, #192–#199).

### Changed

- **Observer state is now keyed to the variable binding, not the Value
  object** (#262). Each binding carries its own entropy/dH trajectory on a
  per-`(env, slot)` `ObserverSlot`, observed eagerly at assignment. The old
  model stored observer state on the recyclable, ref-shared `Value` object,
  so a convergence iterate built through temporaries that alias the variable
  (the normal solver shape — `cand is x*0.1; … ; x is cand`) never
  accumulated a trajectory and `report`/`converged` stalled at the
  partial-window `equilibrium` fallback even at rest. With slot-keying, such
  loops converge correctly. Numbers are now always immediate doubles — they
  never get heap-boxed to carry observer state — which also removes per-binding
  observer allocations from the hot path.
- Behavior delta at the edges: `report` / `observe` / bare `where`·`why`·`how`
  applied to a **non-binding** expression (a computed value or an unobserved
  parameter, which has no trajectory) now return the no-observation defaults
  (`"equilibrium"` / `[…,0,0,0]` / `0`). The same interrogatives on a bound
  name are unchanged — they read the binding's slot.

### Removed

- The `EIGS_OBS_SHADOW` value-path escape hatch and the entire value-path
  observer machinery (the per-`Value` observer fields, the `TAG_TRACKED` slot
  tag, `make_tracked_num`) — the slot model is the only observer model (#262).

### Fixed

- `record_history` now raises on a non-numeric flag instead of silently
  coercing it to `0` (disable). Previously `record_history of null` (or a
  string) turned per-assignment history recording **off** — the opposite of
  the function's purpose — which then made `prev of x` and the `at`-temporal
  queries return `null` with no error, hard to trace back to the call. It also
  overrode the auto-enable the compiler performs for a temporal query. Now a
  non-number flag errors, matching the strict-input direction of #245/#246.
  (#255, found by the `dynamics` consumer as F-DYN-1.)

## [0.16.3] — 2026-06-19

Makes observer-based loop-halting opt-in. An observed `loop while` no longer
auto-halts on the global observer's convergence unless its condition is itself
observer-based (references a predicate) — so plain loops can't be silently
truncated by cross-talk from what their body, or a callee, happened to assign.
Fixes undocumented behavior; the `loop while not converged` idiom is unchanged.

### Changed — observer loop-halting is now opt-in (compositional)

- An observed `loop while` was auto-halted when the **global** last-observer
  showed convergence for ~100 iterations — for **every** `loop while`, including
  plain counting loops that never mention a predicate. Because the watched
  observer is global, a loop's termination could be changed by what its body, or
  a function it called, happened to assign — non-local cross-talk that silently
  truncated loops with no error. (Surfaced by the liferaft DST: a bounded
  `loop while step < 1000` halted at step 146; the sim's outcome depended on
  incidental surrounding assignments.)
- Now the convergence-halt is **opt-in**: it applies only when the loop
  **condition is observer-based** (references a predicate — `loop while not
  converged`, etc.). A plain loop runs until its own condition is false. Both
  keep the absolute iteration cap (the runaway-loop guard). The compiler
  classifies the condition once and emits `OP_LOOP_STALL_CHECK` (observer-based)
  or the new `OP_LOOP_CAP_CHECK` (plain); both the interpreter and the JIT key
  off that compile-time opcode, so they can never disagree on the
  classification.
- `loop while not converged` and the existing halting tests are unchanged.
  Behavior change only for plain `loop while` loops that were being silently
  halted by observer cross-talk — those now run to completion.
- Tests: `tests/test_loop_halting.sh` pins the classifier at the boundary
  (predicate under `not`/`and`/`or` → observer-based; plain comparisons →
  plain) and checks the interpreter and JIT agree. `docs/SPEC.md` updated.

## [0.16.2] — 2026-06-19

A correctness patch. `load_file` no longer silently swallows parse errors — it
raises them like `eval`/`import` do — and the two latent stdlib bugs that
change immediately exposed (a function that never loaded, a variable that never
took effect) are fixed, with a guard so the whole class stays visible. No
behavior change for any file that already parsed cleanly.

### Fixed — `load_file` now surfaces parse errors instead of silently running a partial AST

- `load_file` parsed the target file but never checked `g_parse_errors`, so a
  file the parser couldn't fully accept was compiled and executed as a partial
  (incorrect) AST with **no error** — a statement the parser rejected would
  silently do nothing. Direct execution aborts on a parse error; `import` and
  `eval` already raise; `load_file` was the one path that swallowed it. It now
  raises a catchable runtime error (`load_file: parse error in '<path>'`),
  matching `eval`/`import`. Found by the liferaft DST: an expression-rooted
  lvalue (`(call).field is x`) — which direct execution rejects — was silently
  accepted inside a `load_file`'d module, dropping the assignment.
- Regression: `tests/test_import_errors.eigs` (a `load_file` of a file with an
  expression-rooted-lvalue parse error raises and is catchable; a clean
  `load_file` still executes normally). No change for any file that parses
  cleanly (the entire stdlib and suite are unaffected).
- Two silent `g_parse_errors++` sites in `parser.c` (unexpected token in
  expression; statement that made no progress) now print
  `Parse error line N: ...` with the token, like `p_expect` — the class was
  hard to diagnose because these incremented the count with no message.

### Fixed — stdlib `when` combinator never loaded; renamed to `apply_when`

- With parse errors now visible, a sweep of the stdlib found
  `lib/functional.eigs` defined a function named `when` — a reserved
  interrogative keyword — so `define when(...)` never parsed. The `when`
  combinator was documented in `docs/STDLIB.md` but callable nowhere (its
  parse error was swallowed at `load_file` time). Renamed to **`apply_when`**;
  `docs/STDLIB.md` updated. Sibling of `lib/lab.eigs`'s `stable` (a variable
  shadowing the `stable` predicate keyword), fixed the same way. Both are
  behavior-restoring: the helpers work for the first time.
- Guard: `tests/run_all_tests.sh` now parse-checks every `lib/*.eigs` (via
  `--lint`, which parses without executing), so any identifier shadowing a
  reserved keyword — or any other stdlib parse error — fails the suite loudly
  instead of being silently swallowed.

## [0.16.1] — 2026-06-19

A correctness-and-robustness patch on top of 0.16.0. It closes a remote,
unauthenticated HTTP denial-of-service (a `Content-Length` SEGV), drives the
ASan leak tally from 10 down to 4 (the spawn-thread floor) across the runtime,
HTTP, and `store` extensions, recovers the JIT/OSR acceleration that the #211
leak fix had to give up (~34% on observed-assign hot loops), and hardens the
build against the implicit-declaration pointer-truncation class that caused the
DoS. No language-surface behavior changes versus 0.16.0.

### Docs — the implicit `n` parameter shadows an outer `n` (#241)

- A `define` with no parameter list gets one implicit parameter named `n`
  (existing, documented behavior — `define double as: return n * 2`). #241
  reported `n is expr` inside such a function failing to update an outer `n`
  as a "name-dependent scope bug." It is not a bug: `n` is a bound parameter,
  and parameters shadow outer bindings like any other name (`define g(x)` with
  an outer `x` shadows it identically; `define g()` ≡ `define g(n)`). `SPEC.md`
  now states this explicitly, with a runnable example; `test_scope_semantics`
  pins it (SS7A–SS7F). Documentation only — no behavior change.

### Fixed — `lib/lab.eigs` leaked experiment store handles (#233)

- `lab` functions assigned internal variables without `local`. Per the
  documented scope rule (`name is expr` updates an enclosing binding of the
  same name if one exists), `load`'s internal `exp`/`vals` **clobbered a
  caller's same-named variables** — repointing the caller's experiment at
  `load`'s store handle and orphaning the original, which then leaked
  (uncloseable). `load` now declares all its internals `local`. Added a
  `close_experiment(exp)` helper; `test_lab` closes both experiments.
- Clears `test_lab` under ASan; harness leak tally **5 → 4**. The remaining
  4 are all spawn-thread programs (cycle collector off once multithreaded) —
  the floor without a threaded GC.
- (Surfaced a separate VM bug while diagnosing: scope resolution is
  name-dependent — `n` uniquely ignores the update-outer rule. Tracked as
  #241.)

### Hardening — `-Werror=implicit-function-declaration`

- Added `-Werror=implicit-function-declaration` to the build flags (Makefile
  `CFLAGS` and `build.sh`). An implicitly-declared function is assumed to
  return `int`, so a pointer-returning function compiled without its prototype
  has its return truncated to 32 bits on 64-bit — a corrupted pointer that
  crashes at runtime, layout-dependently. That class just caused a remote DoS
  in the HTTP server (the `strcasestr`/`_GNU_SOURCE` SEGV) and slipped through
  CI as a mere warning. It's now a hard build error. The buildable surface is
  warning-clean, so this is a no-op today except as a regression gate.

### Fixed — HTTP server crash (SEGV) on any request with a Content-Length header

- **Security/robustness:** the server segfaulted on any request carrying a
  `Content-Length` header (a malformed `Content-Length: -1` was the repro) —
  a remote, unauthenticated denial-of-service. Root cause: `ext_http.c` used
  `strcasestr` (a GNU extension) without defining `_GNU_SOURCE`, so it was
  implicitly declared as returning `int`. On 64-bit, its `char*` result was
  truncated to 32 bits and sign-extended back, producing a corrupted pointer
  (`0xffffffff……`) that the subsequent `strtol` dereferenced. Fixed by
  defining `_GNU_SOURCE` before the includes so the real prototype is used.
- The body-length validation logic was already correct (rejects negative /
  oversized with 400) — it just never ran, because the corrupted pointer
  crashed first. With the prototype fixed, `Content-Length: -1` now returns
  400 and the server survives.
- `tests/test_http_server.sh` goes from 9/28 to **28/28**. Swept the full
  http build for other implicit declarations — none. (This was previously
  mistaken for env flakiness; it was a real crash. The default
  `run_all_tests.sh` skips the http suite when the binary lacks `http_route`,
  so it went unnoticed.)

### Fixed — per-request leaks in HTTP `code` routes (#236, ext_http.c)

- The `code`-route handler parsed the route source per request but never
  freed the resulting AST, never freed the parsed auth-source AST, and never
  released the `Value` returned by `vm_execute` for either — so a
  long-running server leaked the AST + chunk + result **on every request**
  (and twice on authed routes). `compile_ast` does not take ownership and
  `vm_execute` returns an owned ref; both route paths now `free_ast` and
  `val_decref` like every other call site (`main`, `load_file`, `eval`).
- Measured (release http, 2000 code-route requests): VmRSS growth **67 MB →
  1.5 MB** (≈33 KB/request → flat). Verified via RSS rather than the ASan
  suite because the blocking server has no clean-exit path and the http
  integration suite is environment-flaky on the dev box (CI runs it).

- A program with a **parse error** leaked its partial AST: `parse` returns a
  partial tree even on error, and the abort branches in `main` (top-level
  run) and the `vm_run` `import` handler (a module that fails to parse) freed
  the token list / source / env but not the AST. Both now `free_ast(ast)` on
  the error path, matching the success path and the #214 `eval` fix.
- Clears `test_import_errors` (and the previously-uncounted `examples/errors/*`
  + `/tmp` parse-error programs); harness leak tally **6 → 5**.

### Fixed — container-builtin reference leaks (builtins.c)

- Four builtins that build a fresh list/dict per element leaked it: the
  *inner* fields were appended with `list_append_owned`/`dict_set_owned`,
  but the *outer* append of the finished container used plain `list_append`
  (which increfs), so the builtin's own ref was never released. Affected:
  `scan_tokens`, `scan_int_tokens`, `tokenize_with_names`,
  `nearest_in_range_all` — each `list_append(out, row)` → `list_append_owned`.
- Clears `test_builtin_indirect` and `test_coverage_gaps` (and the
  marker-only `test_string_math`); harness leak tally **8 → 6**.

### Fixed — reference leaks in the `store` extension (ext_store.c)

- **JSON parser** (`store_json_parse_object`/`_array`): every parsed object
  key leaked a `VAL_STR` (the `key` Value was allocated only to read
  `key->data.str`, then never freed), and parsed values were `dict_set`/
  `list_append`'d (which incref) without releasing the parser's own ref.
  Fixed via `dict_set_owned`/`list_append_owned` + freeing the key carrier;
  error paths now free the partial dict/list/key too.
- **Catalog lifecycle:** `store_close` (and the open error paths) called
  `free(store)` without `val_decref`-ing `store->catalog`, leaking the whole
  parsed catalog dict per store. Centralized in a new `store_free` helper;
  the catalog-rewrite path now drops the old catalog before replacing it.
- **Write path:** `store_put` increfs a new collection's `col_info` into the
  catalog without adopting; `store_update` built arg-lists for internal
  `store_delete`/`store_put` calls and ignored their return values, freeing
  none. All now balanced.
- Clears `test_store` and `test_handle_forge` under ASan; harness leak tally
  **10 → 8**. (`test_lab` still leaks — a separate `lib/lab.eigs`
  store-not-closed lifecycle bug, tracked as a follow-up.)

### Fixed — per-iteration leak in OSR-compiled observed-assign loops, and recovered their JIT coverage (#211, #231)

- **A hot loop that reassigns an *observed* variable in its body
  (`loop while improving: x is refine(x)`, `genetic_optimize`, etc.) leaked
  one `Value` per taken-branch iteration once the loop got OSR-compiled.**
  Root cause: the JIT emitter's `OP_POP` `last_imm` peephole — emit `dec %ecx`
  and skip `slot_decref` when the prior op pushed an immediate — is only sound
  for straight-line code. A *conditional* observed-assign (`if c: x is val`)
  compiles to an if-expression whose false arm pushes `NULL` and whose true
  arm leaves a heap pointer, both merging at a shared `POP`; the `NULL` set
  `last_imm=1`, so the merged `POP` dropped the true arm's pointer without
  decref'ing. Data-dependent (pointer rebinds leaked, number rebinds did not,
  through the *same* emitted code) and OSR-only — which is why #210's windowed
  `converged` exposed it in `genetic_optimize` (it removed an early exit).
- **Fix:** reset `last_imm` at every forward-jump target so a control-flow
  merge can no longer carry a stale immediate flag into the merged `POP`
  (`src/jit.c`). #211 first shipped a conservative stop-gap — the OSR scanner
  declined to compile loops through `OBSERVE_ASSIGN`/`OBSERVE_ASSIGN_LOCAL`,
  costing ≈16–34% on observed-assign hot loops — and #231 replaced it with the
  emitter fix and re-enabled OSR for those loops (n=5 microbench: ~34%
  recovered; standard benches unaffected; JIT output identical to
  `EIGS_JIT_OFF=1`).
- Regression guards: `tests/test_optimize.eigs` runs `genetic_optimize` for
  120 generations (was capped at 80 in #210 to dodge the leak), and
  `tests/test_osr_observe_assign.eigs` pins the conditional-merge case (it
  leaks 479 objects with the fix reverted). Both re-leak under ASan and bump
  the harness tally on regression.

## [0.16.0] — 2026-06-18

The #202 windowed-predicate series: all six observer predicates
(`converged`, `stable`, `oscillating`, `improving`, `diverging`,
`equilibrium`) now read a window of the last N observations instead of the
instantaneous `dH`, so they describe the recent trajectory and no longer
flicker on a single noisy step. The bands form an explicit lattice
(`converged ⊂ equilibrium`, high-entropy `equilibrium ⊂ stable`) and
`report` resolves the most specific. See docs/PREDICATES.md.

### Change — `stable` and `equilibrium` are now windowed predicates (#205, #209)

This completes the #202 windowed-predicate series: all six observer
predicates now read the dH window instead of the last step.

- **`equilibrium` (#209)** — new helper `observer_equilibrium`: full window
  (`count == N`) AND `|mean(window)| < dh_zero` AND
  `variance(window) < dh_zero²`. The value is at rest on average with
  negligible spread, regardless of entropy.
- **`stable` (#205)** — new helper `observer_stable`: full window AND every
  `|dH| < dh_small` AND `entropy >= h_low` AND no consecutive sign flips
  (adjacent opposite-sign pair both clearing `dh_zero`). Small but nonzero
  motion at high information content, holding direction.
- **The quiescent lattice is now explicit.** `converged ⊂ equilibrium`, and
  a *high-entropy* `equilibrium ⊂ stable`. A full quiet window is therefore
  `converged` (low entropy) or `equilibrium`+`stable` (high entropy);
  `equilibrium` never fires alone, and `report` resolves to the most
  specific band (`converged` then `equilibrium` then `stable`).
- **User-visible delta:** both predicates now require a *full* window
  (`count == N`) like `converged`, so a value at rest reports `stable` /
  `equilibrium` only after N observations, not on the first quiet step. For
  partial windows `report` falls back to an instantaneous best-effort label
  (see docs/PREDICATES.md → The `report` builtin), so `report`-driven code
  such as `lib/simulation.eigs` is unaffected.
- New tests: `tests/test_windowed_stable.eigs` (suite [8g]) and
  `tests/test_windowed_equilibrium.eigs` (suite [8h]), 8 checks each. The
  predicate matrix's `stable`/`equilibrium`/`converged` cases, the
  threshold-knob, and the `stable_band` / `halting_stall` /
  `report_alignment` / `windowed_converged` tests were migrated to
  full-window sequences. Two of those also surfaced (and now avoid) the
  last-observer-alias gotcha: reading `c is converged` before
  `e is equilibrium` repoints the alias, so both predicates are now read
  against the value in a single list expression.

### Change — `oscillating` is now a windowed predicate (#206)

- **`oscillating` and `report of x == "oscillating"` now count sign flips
  across the dH window instead of looking at the last two steps.** New
  shared helper `observer_oscillating` (used by both the `PREDICATE` op kind
  3 and the report builtin) is: `window_size >= 3` AND at least
  `FLIPS = ceil(N/3) = 4` sign flips across the window, where a flip is an
  adjacent dH pair with opposite signs whose magnitudes *both* clear
  `dh_zero` (sub-noise wobble does not count).
- **Deadband stays at `dh_zero`, not `dh_small`.** Unlike `improving` /
  `diverging`, oscillating is a deadband-escape test, not a direction
  verdict, so #187 deliberately left it on `dh_zero`: a gray-band
  alternation (`dh_zero < |dH| < dh_small`) still reads `oscillating`.
- **User-visible delta:** a single reversal (or one or two flips) in an
  otherwise monotone trajectory no longer reads `oscillating` — sustained
  back-and-forth now requires ≥ 4 flips, i.e. ≥ 5 observations / 4
  alternating steps. The old pointwise rule fired on the first sign flip.
- New tests: `tests/test_windowed_oscillating.eigs` (suite [8f], 8 checks:
  large/gray-band alternation, the exactly-4-flips boundary, sub-threshold
  flip counts, sub-noise wobble, monotone, single reversal, partial window).
  The predicate matrix's oscillation cases and `test_report_alignment` RA4
  were extended to sustained alternations (7 samples).

### Change — `diverging` is now a windowed predicate (#208)

- **`diverging` and `report of x == "diverging"` now read the dH window
  instead of the last step**, as the exact mirror of windowed `improving`
  (#207). New shared helper `observer_diverging` (used by both the
  `PREDICATE` op kind 4 and the report builtin) is:
  - `window_size >= 3`;
  - **`sum(window) > 0`** — net entropy *ascent* (magnitude-aware): a run
    that ends *more* determined than it started is never `diverging`, even
    if most steps ticked up;
  - **`up_fraction >= 0.6`** — ≥60% of steps are genuine ascents
    (`dH > +dh_small`), the proportional vote, with the `dh_small` threshold
    keeping a gray-band ascent out of `diverging` (it reads `stable`,
    honoring the #187 contract).
- **Mutual-exclusivity win:** a large-amplitude oscillation no longer
  co-fires `diverging`. The old pointwise rule (`dH > dh_small`) fired
  whenever the *last* tick happened to be a large up-step, so an
  oscillation read as both `oscillating` and `diverging`; the windowed rule
  needs a net trend + directional majority, which an oscillation has
  neither of. `report` still resolves `oscillating` first.
- **User-visible delta:** a noisy ascent (net up, majority of steps
  genuinely rising) reads `diverging`; a *net-improving* run, a *gray-band*
  steady ascent, and a sustained *oscillation* do not; fewer than 3
  observations never report `diverging`.
- New tests: `tests/test_windowed_diverging.eigs` (suite [8e], 8 checks
  mirroring [8d]). The predicate matrix's large-oscillation edge case now
  asserts `diverging = 0`, and `test_report_alignment` RA1 was migrated to a
  multi-step ascent.

### Change — `improving` is now a windowed predicate (#207)

- **`improving` and `report of x == "improving"` now read the dH window
  instead of the last step.** The pointwise rule (`dH < -dh_small`) fired
  on a single negative tick and dropped the claim the next frame if entropy
  bounced — it flickered under noise, which is the wrong behavior for the
  canonical `loop while improving` use. The windowed rule (shared helper
  `observer_improving`, used by both the `PREDICATE` op and the report
  builtin) is a hybrid of three independent tests:
  - `window_size >= 3` (partial-window rule — no claim on < 3 samples);
  - **`sum(window) < 0`** — the entropy fell on *net* over the window. This
    is magnitude-aware: a trajectory that ends with *higher* entropy than it
    started is never `improving`, even if most individual steps ticked down.
  - **`down_fraction >= 0.6`** — at least 60% of the steps are *genuine*
    descents, where a descent step is `dH < -dh_small`. The proportional
    vote (rather than an absolute bounce cap) tolerates noisy up-ticks
    without dropping a real descent; the `dh_small` threshold keeps a
    gray-band descent out of `improving` (see below).
- **This is a deliberate hybrid, not a restoration of any ancestor rule.**
  The legacy EigenChat *language* predicate was pointwise (radius
  decreasing), and its only *windowed* notion (`TemporalLossState`) was a
  magnitude-blind directional ratio vote that reports "improving" even on a
  net-worsening run. We keep that rule's noise tolerance (the proportional
  vote) but add the `sum < 0` magnitude gate so a net-worsening trajectory
  is never called improving.
- **Honors the #187 gray band.** The descent threshold is `dh_small`, not
  `dh_zero`, so a steady descent inside the gray band
  (`dh_zero <= |dH| < dh_small`) reads `stable`, not `improving` — the
  predicate family stays mutually exclusive and `improving` remains the
  windowed generalization of the pointwise rule it replaced.
- **User-visible delta:** a noisy descent (net down, majority of steps
  genuinely descending) now reads `improving` where the first windowed cut
  dropped it on a couple of bounces; a *net-worsening* run and a *gray-band*
  steady descent both read `stable`/their true state rather than
  `improving`; fewer than 3 observations never report `improving`.
- New tests: `tests/test_windowed_improving.eigs` (suite [8d], 8 checks
  covering monotone/noisy descent, net-up, gray-band, sub-majority, flat,
  ascent, and partial window). The predicate matrix's "stable" canonical
  case is a slow ascent so it stays stable-only under the new rule.

### Change — `assert` failures are now catchable (#220)

- **`assert of [cond, msg]` and `assert of cond` no longer call
  `exit(1)` on failure.** They set `g_has_error` + `g_error_msg` and
  return null, exactly like `throw`, so `vm_run` unwinds through any
  enclosing `try`/`catch` (catch binds the `"ASSERT FAIL: <msg>"`
  string). An uncaught assert still prints `ASSERT FAIL: <msg>` to
  stderr and exits non-zero — same observable behavior for scripts
  that don't wrap asserts in `try`.
- **Why the change:** `exit(1)` bypassed `main`'s teardown
  (`env_decref` of the global scope, `gc_collect_at_exit`,
  `chunk_free`), leaking every registered builtin + the global env +
  the AST every time an assertion failed. ASan flagged 25 KB / 198
  objects on `tests/test_assert_fail.eigs`. The runtime-error path is
  the canonical leak-clean way to abort.
- Programs that relied on assert being uncatchable (none known in
  the suite or examples) should restructure to use a sentinel that
  the catch handler rethrows, or fail the test by other means.

### Change — `converged` is now a windowed predicate (#204)

- **`converged` and `report of x == "converged"` now require a full
  10-step quiet window.** The pointwise rule (`|dH| < dh_zero &&
  entropy < h_low` on the current step alone) flagged any single-step
  quiet as converged, which fires spuriously on iterative schemes
  whose first quiet step is followed by more motion — Newton's method
  early in the descent, gradient descent crossing a saddle, an SA
  trajectory that happens to hold its energy for one step. The new
  rule requires the most recent `OBSERVER_WINDOW_N = 10` `dH` values
  to all be below `dh_zero` *and* current entropy below `h_low`. A
  value observed fewer than `N` times can no longer report
  `converged`; it reports `equilibrium` if `|dH| < dh_zero` or one
  of the active-trajectory bands otherwise. See
  [docs/PREDICATES.md](docs/PREDICATES.md) for the full spec.
- **Behavior change for short trajectories.** Programs that relied on
  `converged` firing after 1-2 assignments will now see `0` /
  `equilibrium`. The fix is to either prime with more observations or
  read `equilibrium` (which is still pointwise) for short runs. Loops
  that watch `loop while not converged` may run more iterations
  before exiting; ensure their `max_iter` cap is sufficient.
- **Internal:** lazy `dh_window` ring buffer on each tracked Value;
  allocation is gated on the compile-time observer-tracking flag, so
  values that no predicate or interrogative reads pay nothing. Buffer
  is moved (not copied) on `OBSERVE_ASSIGN` and freed before the
  VAL_NUM freelist path. Spec: [docs/PREDICATES.md](docs/PREDICATES.md).

### Fixed — memory-safety fixes since 0.15.3 (#212, #213, #214)

- **#212** — the VM builtin-arg wrapper heap-forces its list, so heap items
  stored in an arena-window container no longer leak their refs on arena
  reset.
- **#213** — `VAL_NULL` is no longer promoted to the heap (the singleton
  stays immortal); `slot_bridge_wrap` releases the heap-null refs it drops
  into the immediate-null slot encoding.
- **#214** — `eval` frees the partial AST returned by `parse` on the
  parse-error branch.

Together these dropped the ASan harness leak tally from 13 to 10.

## [0.15.3] — 2026-06-16

### Fix — `\r` is now a string-literal escape

- **`"\r"` produces ASCII CR (0x0D) instead of the literal char `'r'`.**
  The lexer's escape switches (regular `"..."` and f-strings `f"..."`,
  `src/lexer.c`) only handled `\n`, `\t`, `\`, and `\"`; `\r` fell to
  the default branch, which dropped the backslash and kept `'r'`. Real
  on-disk CRLF in files was always handled correctly by the C scanners
  (`scan_ints`, `scan_int_tokens`, `scan_tokens`) because `isspace('\r')`
  is true — the gap only bit anyone constructing CRLF test data inline.
- **Behavior change for any program that wrote `"\r"` and expected `'r'`**
  (unlikely; the escape was undocumented). To get a literal `'r'`,
  remove the backslash.

### Fix — observer predicates honor the gray band (#187)

- **`improving` / `diverging` now switch at `dh_small`, matching
  `report`.** Previously they switched at `dh_zero`, so in the gray
  band (`dh_zero ≤ |dH| < dh_small`) the predicates collided with
  `stable` (which already used `dh_small`) and disagreed with
  `report of x`. A value parked at `dH = -0.005` with default
  thresholds read as **both** `stable` and `improving` simultaneously
  while `report` returned `"stable"`. The predicate family is now
  internally consistent and agrees with `report` across the whole
  range. `oscillating` is unchanged — it gates on `dh_zero` as a
  deadband-escape test, not a direction verdict.
- **Behavior change for documented predicates.** Programs reading
  `improving` or `diverging` in the gray band will now see `0` where
  they previously saw `1`. The `report` keyword, the predicate-vs-
  report contract, and `stable` are unchanged.

## [0.15.2] — 2026-06-15

### Fix — macOS Intel JIT enabled

- **macos-x86_64 ships with the JIT live again.** The 0.14.2 holding
  pattern (`EIGENSCRIPT_JIT_FORCE_OFF=1` on Darwin x86_64) is gone. The
  root cause was that the JIT prologue inlined Linux ELF
  `mov %fs:eigs_current_tpoff, %rbx` for TLS, which has no Mach-O
  equivalent — every thunk SIGSEGV'd on first entry. Fix:
  - Prologue is platform-split. Darwin calls a C helper
    `eigs_jit_load_eigs_current()` in `src/vm.c` (the C compiler emits
    the TLV descriptor sequence around the load) and copies `%rax` to
    `%rbx`. Linux keeps the inline `%fs:tpoff` read. End-state is the
    same — `%rbx = EigsThread*` — and the existing
    `mov off_thread_vm(%rbx), %rbx` resolves the VM pointer identically
    on both.
  - Mid-thunk reads of `eigs_current` (unobserved_depth guards) can't
    derive the thread back from `%rbx` because `vm` is a heap-allocated
    `VM*`, not embedded. Added `struct EigsThread *owner` to `VM` (set
    in `vm_init`), exposed via `off_vm_owner` in `EigsJitLayout`. The
    three mid-thunk sites do `mov off_vm_owner(%rbx), %rax` followed by
    a probe at `off_thread_unobserved_depth(%rax)`. Same encoding on
    both platforms — no `#ifdef` in the thunk body.
  - The dict-field inline cache stays off on Darwin (`dcache_ways=0`
    in the layout trips the existing `dcache_ways == 2` guard), so
    `LOCAL_DOT_GET/SET` route to the slow-path helper. Porting the
    inline probe is the only remaining Darwin-specific follow-on.
- **CI**: `macos-15-intel` is now in the `build-and-test` matrix, so
  every push runs the full 1855-check suite with JIT live on macOS x86_64.
  The `[82]` thunk-gate's Darwin skip is gone.
- `EIGENSCRIPT_JIT_FORCE_OFF` stays in `src/jit.c` as a bisection kill
  switch but is no longer set by `build.sh`.

## [0.15.1] — 2026-06-15

### HTTP `http_route_authed`: source-based auth via shared store

- `http_route_authed`'s auth check now resolves the auth source from
  `shared_get("require_auth")` first, with the legacy
  `require_auth`-function fallback in the worker env preserved for
  back-compat. When the shared key is a string, the worker tokenizes/
  parses/compiles/executes it per request in a fresh env on top of
  the worker's global. Empty `value_to_string` result = allow; any
  non-empty result becomes the 401 body verbatim.
- Closes the multi-state gap that broke `http_route_authed`: a
  function value can't cross worker boundaries (each worker dies with
  its arena), but a *string source* can — and re-evaluating it per
  request reaches the same semantics. Hosts publish a session table
  or token-validity flag via `shared_set` and write the auth check as
  a small script that consults it.
- Tests: HS24–HS26 in `tests/test_http_server.sh` — `/asetup` seeds
  `require_auth` as the source `shared_get of "auth_msg"`; flipping
  `auth_msg` between `""` and `"denied by test"` toggles 200/401, and
  the message round-trips into the 401 body. HS26 proves the source
  is re-evaluated per request, not cached at registration.

### HTTP shared store: `shared_incr(key, delta)` for atomic counters

- New builtin `shared_incr of [key, delta]`. Single-lock read-modify-
  write — reads current numeric value, adds `delta`, writes back, and
  returns the new value, all under the existing shared-store mutex.
  Missing key is treated as 0 (so the first call inserts the key);
  an existing non-numeric value is a usage error and returns `null`
  without mutating. Subject to the same byte cap as `shared_set`.
- Closes the RMW gap the original `shared_set + shared_get` API had:
  HS23 fires 32 concurrent `/sinc` calls and verifies that every
  integer in 1..32 appears exactly once in the responses and the next
  call returns 33. Holds under ASan slowdown too.

### HTTP shared store: bounded by `EIGS_HTTP_SHARED_MAX_BYTES`

- Total key + JSON-value bytes across the shared store are now capped
  (default 64 MiB; override via env). `shared_set` rejects writes that
  would push the total past the cap and returns `null` without mutating
  storage — predictable refusal, no eviction.
- HS22 in `tests/test_http_server.sh` verifies the cap: a server
  launched with `EIGS_HTTP_SHARED_MAX_BYTES=4096` rejects an 8 KiB
  write, and `shared_has` confirms the store stayed clean.

### HTTP shared store: cross-worker key/value primitive

- **New builtins**: `shared_set(k,v)`, `shared_get(k)`, `shared_has(k)`,
  `shared_delete(k)`, `shared_keys()`, `shared_size()`, `shared_clear()`.
  Available in main and worker code-route contexts (registered via
  `register_http_request_builtins`, so workers get them automatically).
- **Storage**: keyed map on the main `EigsHttpServer`. Values are
  JSON-serialized on `shared_set` (`eigs_json_encode`, now publicly
  exposed) and re-parsed on `shared_get` into a value owned by the
  caller's `EigsState`. JSON-as-storage sidesteps cross-state `Value*`
  lifetime — workers die with their arena, the stored string stays
  heap-owned by the Server.
- **Concurrency**: a `pthread_mutex_t` on the Server guards every op,
  so individual reads/writes are atomic. The API does **not** provide
  read-modify-write atomicity (no CAS / increment primitive yet) —
  scripts that need it must serialize externally, or risk losing
  updates under concurrent writers.
- **Effect on `http_route_authed`**: a startup script can now publish
  a session table (or token-validity flag, or rate-limit bucket) via
  `shared_set`, and authed `code` routes look it up via `shared_get`.
  Function values still can't be shared (encoded as `null` per
  `json_encode` semantics) — the route source itself runs the auth
  check, what crosses the worker boundary is the *data* it checks.
- **Tests**: HS17–HS21 in `tests/test_http_server.sh` — string and
  nested-dict round-trips across worker states, `shared_delete`,
  `shared_clear` + size, 32 concurrent `shared_get` calls all return
  the intact value.

### HTTP `code` routes evaluate in a per-worker `EigsState` (concurrency + isolation)

- **Each connection now runs its `code` route in a fresh worker
  `EigsState`** (created in `http_conn_thread` via `eigs_state_new` +
  `eigs_thread_attach` + `register_builtins`). The worker's global env
  starts empty — `code` route source has access to stdlib and the
  per-request HTTP builtins, but **does not see any globals defined
  by the startup script**, and mutations in one request never leak
  into another.
- **Why this changes behavior.** Previously, workers were detached
  pthreads that set `eigs_http_active` but never called
  `eigs_thread_attach`, so `vm_execute` inside a worker ran with
  `eigs_current == NULL` and the bridge macros derefed null — `code`
  routes were structurally unsafe from worker threads. With a real
  `EigsState` attached per worker, they're safe to evaluate, including
  concurrently across many connections.
- **Migration:** `code` routes that closed over startup-time globals
  (counters, route registries, request logs) will see those globals
  missing. To share state across requests, use a host-provided shared
  store (planned next; until then, `code` routes must be self-contained
  or read shared state through `http_post`/file I/O). `http_route_authed`
  regresses to 500 unless `require_auth` is self-contained in the route
  source — auth on shared session state is blocked on the shared-store
  primitive.
- **New tests:** `tests/test_http_server.sh` HS14 (code route runs and
  returns the last expression), HS15 (10 sequential calls each see
  fresh state), HS16 (16 concurrent calls all return the isolated
  value — proves no cross-worker globals trampling).
- **Internal split:** `register_http_request_builtins` exposes the
  read-the-current-request subset (`http_request_body`,
  `http_session_id`, `http_request_headers`, `http_post`) without
  allocating a `Server` — useful for any future embedder that wants
  to host code routes from its own worker pool.

## [0.15.0] — 2026-06-15

### Embedding API — `eigs_embed.h` makes the runtime hostable from C (multi-state refactor, Phase 10)

- **Public C surface for embedding EigenScript in a host program.**
  `src/eigs_embed.h` exposes a small, opaque API: state/thread
  lifecycle (`eigs_open`/`eigs_close`, or the finer-grained
  `eigs_state_new` + `eigs_thread_attach` + `eigs_state_init_runtime`
  for hosts that need to attach multiple OS threads to the same
  state), source eval (`eigs_eval_string`, `eigs_eval_file` — both
  REPL-style, so top-level names accumulate in the global env and
  the host can read them back through `eigs_get_global`), error
  retrieval (`eigs_last_error_message`/`eigs_has_error`/
  `eigs_clear_error`), ref-counted `EigsValue` handles with
  num/string/list/dict constructors + type inspection + accessors,
  and FFI registration (`eigs_register_function` adopts the existing
  `BuiltinFn` shape so a C function receives a single `EigsValue *arg`
  — raw value for 1-arg calls, `VAL_LIST` for multi-arg).
- **`src/embed_smoke.c` is the contract test.** A standalone host
  harness that registers a `host_add` C function, evaluates scripts
  that read host-set globals and call back into C, and checks the
  error path through an undefined-name lookup. Wired up as `make
  embed-smoke` (links the runtime minus `main.c` the same way `make
  fuzz`/`make lsp` do, so it stays in lockstep with the runtime).
- **Wraps the multi-state refactor (Phases 1–9, lifted every
  `__thread` global onto `EigsState` per-interpreter or `EigsThread`
  per-OS-thread).** The embedding API is what those nine phases were
  building toward — they did the structural work; Phase 10 just gives
  embedders a stable, opaque contract that doesn't expose the
  internal bridge-macro identifiers (`g_global_env`, `g_has_error`,
  etc.). Net effect: a C/C++ host can now embed multiple interpreter
  instances concurrently in the same process, each with its own
  global env, JIT cache, module cache, observer thresholds, and
  per-thread arena/error state.
- Suite: release 1855/1855; ASan 1855/1855 with the unchanged
  13-program leak tally. All variants (release, http, lsp,
  jit-smoke, embed-smoke) build clean.

### Package tool — `<owner>/<name>` is now required

- **`--pkg add` rejects bare package names.** Identifiers must be
  `<owner>/<name>` (e.g. `alice/tensor`); `install`, `update`, and
  `verify` also fail-fast on a manifest with bare-name dep keys.
  Reserving the namespace at the manifest layer from day one
  prevents a popularity spike from fragmenting it onto bare leaves;
  bare-name retrofit would otherwise be unrecoverable since every
  shipped lockfile would already have keys baked in. On-disk layout
  and the user-facing `import <name>` form stay flat (the leaf, just
  `<name>`) — two packages with the same leaf still can't coexist,
  but disk-level nesting and scoped imports can land later without
  breaking existing manifests. README, CONTRIBUTING, PACKAGE_DESIGN
  updated; `tests/test_pkg_{fetch,verify_update,skeleton}.sh` cover
  the new rejection paths.

## [0.14.2] — 2026-06-13

### Ship — macOS Intel binary, interpreter-only

- **macos-x86_64 release binary now ships JIT-disabled at build time.**
  The MAP_JIT switch in 0.14.1 wasn't enough — thunks still SIGSEGV on
  first entry on the macos-15-intel runner, with a failure pattern that
  doesn't match the standard hardened-runtime symptoms (Intel
  pthread_jit_write_protect_np is a no-op, MAP_JIT is set, the compile
  is clean, simple interpreter tests pass). Root cause is unresolved
  and not reproducible without a macOS Intel machine, so 0.14.2 takes
  the pragmatic route: `build.sh` defines
  `EIGENSCRIPT_JIT_FORCE_OFF=1` when `uname -s = Darwin && uname -m =
  x86_64`, `src/jit.c`'s `jit_try_compile_chunk[_osr]` honor it as an
  early return, and `tests/run_all_tests.sh`'s `[82]` thunk-gate skips
  on Darwin x86_64 the way it already does on non-x86_64. Net effect
  for users: the macos-x86_64 binary is interpreter-only (≈3–5× slower
  on hot loops); correctness is unchanged. macOS arm64 was already
  interpreter-only (no ARM64 emitter yet), so this gap is now
  consistent across Apple platforms. v0.14.0 and v0.14.1 tags exist on
  the remote but never produced artifacts — first published release of
  the 0.14 line is 0.14.2.

## [0.14.1] — 2026-06-13

### Fix — macOS Intel JIT page mapping

- **JIT cache pages now use `MAP_JIT` + `pthread_jit_write_protect_np`
  on Apple platforms.** The previous
  `mmap(PROT_READ|PROT_WRITE)` → `mprotect(PROT_READ|PROT_EXEC)` W→X
  transition is rejected under macOS 15's hardened runtime — every
  thunk SIGSEGV'd on first entry, taking 348/1857 tests down on the
  macos-15-intel runner during the 0.14.0 release build. The
  macos-x86_64 runner is new for 0.14.0; v0.13.0's single-job workflow
  never exercised it, so the failure mode was latent. `src/jit.c`
  branches on `__APPLE__` for the mapping flags and seal/unseal
  primitives; Linux behavior is unchanged. macos-arm64 stays
  interpreter-only (the JIT itself remains x86_64-gated).
- Suite remains 1857/1857 release + ASan with `detect_leaks=1` (leak
  tally still 13).

## [0.14.0] — 2026-06-13

### Trust/identity — OpenSSF badge, CodeQL, Scorecard 7.5/10, signed releases, OSS-Fuzz in flight

- **OpenSSF Best Practices passing badge earned** (project 13187,
  100% at 2026-06-13 09:27 UTC —
  https://www.bestpractices.dev/projects/13187). Badge embed lives in
  the README alongside CI/Release/License/Stars. Silver sits at 13%
  and gold at 22%; the gaps are governance/DCO/vulnerability-response
  process families, not core security work.
- **CodeQL workflow** (`.github/workflows/codeql.yml`) runs the
  `security-and-quality` query pack on every push, every PR, and a
  weekly cron — added to satisfy `static_analysis` and to surface
  alerts in the repo's Security tab. Triage the same cadence as
  ASan/leak-tally failures.
- **OpenSSF Scorecard 7.5/10** (`.github/workflows/scorecard.yml`):
  10/10 on twelve checks including SAST, CI-Tests, Fuzzing,
  Dependency-Update-Tool, Pinned-Dependencies, Token-Permissions,
  Maintained, Security-Policy, License, Vulnerabilities,
  Dangerous-Workflow, Binary-Artifacts. Workflow hardening: every
  third-party action is pinned to its commit SHA (Dependabot config
  added for weekly bumps); top-level workflow tokens default to
  read-only with `contents: write` / `pages: write` / `id-token: write`
  scoped to the jobs that need them. Remaining gaps are structural
  (solo Code-Review, Branch-Protection vs. direct-push workflow) or
  bump only at Gold-tier Best Practices.
- **Signed releases via Sigstore build provenance**
  (`actions/attest-build-provenance` in `release.yml`). Every release
  binary — `eigenscript-{linux,macos}-{x86_64,arm64}` and the Linux
  `eigenscript-full` variant — gets a keyless attestation written to
  the GitHub attestations API, plus an `attestation.sigstore.json`
  bundle uploaded alongside the binaries for offline verification.
  Per-binary verification: `gh attestation verify eigenscript-<label>
  --repo InauguralSystems/EigenScript`. This is the first EigenScript
  release to ship signed artifacts.
- **OSS-Fuzz enrollment**: PR google/oss-fuzz#15720 submitted from the
  InauguralSystems org fork with the CLA signed; all checks green
  except trial-build (NEUTRAL, non-blocking). The libFuzzer harness
  (`fuzz/fuzz_eigenscript.c`) was rewritten to drive the current
  bytecode pipeline (the AST-interpreter-era harness had bitrotted),
  paired with a keyword/punctuation/builtin dictionary
  (`fuzz/eigenscript.dict`) and a `make fuzz-libfuzzer` target
  (`clang -fsanitize=fuzzer,address,undefined`).

### Package ecosystem — CONTRIBUTING section + awesome-eigenscript (package design Phase 2)

- **CONTRIBUTING.md gains a "Publishing a Package" section.** Covers
  naming (lowercase identifiers, no hyphens, stdlib name reservations),
  semver discipline (cut new tags rather than force-pushing), the
  privacy convention (leading underscore), the "no top-level side
  effects" footgun, and where to list a published package.
- **New repo: [InauguralSystems/awesome-eigenscript](
  https://github.com/InauguralSystems/awesome-eigenscript).** Curated
  index of packages, tools, learning resources, and editor integrations.
  A list, not a registry — the package tool resolves packages by git
  URL, so this index is purely for discoverability. PRs add one entry
  per package; inclusion gated on tagged release + smoke test in CI.

### Package starter — `eigs-package-template` (package design Phase 1 wrap)

- **New repo: [InauguralSystems/eigs-package-template](
  https://github.com/InauguralSystems/eigs-package-template).** A
  forkable starting point for an EigenScript package: `eigs.json` +
  `<name>.eigs` at the root, MIT license, a smoke test that stages
  the package into `eigs_modules/<name>/` and imports it the way a
  consumer would, and a CI workflow that builds EigenScript from
  source. Tagged `v0.1.0` to demonstrate the semver workflow.
- The Phase 1 design called for this; it lands as a sibling repo
  rather than docs in this tree so authors `gh repo fork` it.

### Package tool — `--pkg verify` + `--pkg update` (package design Phase 1c)

- **`--pkg verify`** re-checks every installed dep against the lockfile.
  Three failure modes per package: the checkout is missing, `HEAD`
  differs from the locked commit, or the working tree has been edited
  (`git status --porcelain` non-empty). Exits nonzero (via `throw`) if
  any package fails so CI can gate on it.
- **`--pkg update [name]`** re-resolves the manifest tag to its current
  `HEAD` and re-locks. With no arg, walks every dep; with a name, only
  that one (unknown name → nonzero exit). The manifest itself is
  unchanged — `update` moves only the lockfile.
- **Lockfile gains a `tree` field**: git's `HEAD^{tree}` SHA, recorded
  by `add` / `install` / `update` and re-checked by `verify`. The
  commit SHA already nails down git history; the tree hash is the
  content-addressed identifier of the tree itself, and pre-1c
  lockfiles are backfilled on the next `install`.
- Suite gains section [96] (`tests/test_pkg_verify_update.sh`,
  7 checks): clean verify, tampered-tree verify, missing-checkout
  verify, update no-op on unchanged tag, update advances lockfile
  after a tag move, unknown-name update exits nonzero, and verify
  accepts the post-update state.

### Package tool — `--pkg add` + `--pkg install` actually fetch (package design Phase 1b)

- **`--pkg add <name> <url> [tag]` now clones the dep** into
  `eigs_modules/<name>/` via `git clone --depth 1 --branch <tag>`,
  resolves `HEAD` with `git -C <dir> rev-parse HEAD`, and records
  `{git, tag, commit}` in `eigs.lock.json`. The manifest write
  happens *before* the network step so a failed clone leaves a
  recoverable on-disk state — re-run `--pkg install` to retry.
- **`--pkg install` reproduces `eigs_modules/` from the lockfile.**
  For each manifest dep: wipe the target dir, re-clone at the manifest
  tag, then — if the lockfile pins a commit — `git fetch --depth 1
  origin <commit>` + `git checkout <commit>` so a force-pushed tag
  cannot sneak a different tree past the lock. Install is idempotent
  (re-running over a populated `eigs_modules/` is a no-op-equivalent
  refresh) and never leaves the tree in a half-state.
- **No code from the dep is executed at install time** — the runtime
  only ever loads `eigs_modules/<name>/<name>.eigs` when the user
  script actually `import`s it.
- Suite gains section [95] (`tests/test_pkg_fetch.sh`): builds a
  local `file://` git repo as a fake remote, runs the full add →
  import → install round-trip, and verifies the lockfile-wins-over-
  moved-tag invariant by force-retagging the source.

### Package tool — `--pkg` skeleton (package design Phase 1a)

- **New CLI: `eigenscript --pkg <subcommand>`.** Dispatcher loads
  `lib/pkg.eigs` and forwards subcommand args to it. Wired alongside
  `--fmt` and `--lint` in `src/main.c`. The tool is written in
  EigenScript itself (`lib/pkg.eigs`) so it dogfoods the JSON,
  subprocess, and file-I/O surface.
- **Subcommands landed: `list`, `add`, `help`.** `add` writes the dep
  to `eigs.json`; `list` prints what's recorded plus the locked
  commit if present in `eigs.lock.json`. `install`, `verify`,
  `update` are stubs in this slice — they land in Phase 1b and 1c.
- **Unknown subcommand exits nonzero** via `throw`, so CI / shell
  pipelines fail loudly on typos. The manifest and lockfile use the
  built-in `json_encode`/`json_decode` — no new dependency.

### Modules — import cache + per-file resolution + eigs_modules/ (package design Phase 0a/b/c)

- **`import name` now searches `eigs_modules/<name>/<name>.eigs`,
  walking upward from the importing file's directory to the project
  root** (a directory containing `eigs.json`, checked once and then
  the walk halts). Only fires for bare `<name>.eigs` requests, so
  paths with directory components fall through the existing chain
  unchanged. Walks are bounded to 64 levels. This is the runtime hook
  for the `eigs_modules/` layout that the future `--pkg` tool will
  populate; the resolver gains the lookup now so a hand-curated
  `eigs_modules/` works today.
- **Resolver ordering.** Within the `import` resolver chain, the
  package step sits between the cwd-relative check and the
  importer-dir (`base`) check, so a packaged dep wins over a
  loose file next to the importer. Stdlib and `eigs_modules/` may
  collide on a name; the future `--pkg add` tool will reject collisions
  at install time per the design.


- **`import` now caches the resolved module.** The first import of a
  module executes its body; subsequent imports of the same resolved
  absolute path bind the same dict and reuse the same module Env. A
  side-effecting top-level statement (e.g. `print of "init"`) runs
  exactly once across all importers; diamond dependencies (`a → c`,
  `b → c`) share one instance of `c`'s state. Cache is keyed on the
  `realpath`-canonicalized resolved path so different relative routes
  to the same file hit the same entry. Cleared in `gc_collect_at_exit`
  before the global-scope snapshot.
- **`import` inside a module resolves relative to *that module's*
  directory.** Previously every nested import searched from the main
  script's directory, so a submodule couldn't reliably reach its own
  peers. Now the resolver's script-relative step anchors at the
  importing file's own directory (derived from its `realpath`-
  canonicalized absolute path, so symlinks and `..` segments are
  flattened). The other steps in the chain (cwd, exe-relative, stdlib
  `$HOME/.local/lib/eigenscript`) are unchanged.
- **Observable behavior change.** Programs that relied on per-import
  re-execution of side-effecting modules will see one execution
  instead. Programs that worked around the main-script-relative
  resolver by placing submodule peers next to the entry point can now
  colocate them with their importer. The dict shape, member names, and
  binding semantics are unchanged. This is the runtime prerequisite
  for the package design (docs/PACKAGE_DESIGN.md) and is documented in
  SPEC.md — Modules.

### Runtime — small perf wins (issue #174)

- **Compiler dedups `OP_LINE` per basic block.** The compiler stamped a
  fresh `OP_LINE` for every AST node, so `total is total + i` emitted
  three back-to-back updates to the same line. Now `emit_line` skips
  the write when the line hasn't moved, resetting at every basic-block
  boundary (jump targets, loop tops, after `OP_CALL`/`OP_DISPATCH`, fn
  entry) so the runtime `current_line` invariant never weakens. Bench:
  `while 100k` 6.45 → 6.05 ms (~6% n=5 median, T3200).
- **String concat allocates once.** `OP_ADD`'s string path went
  `malloc → make_str (strdup) → free` — two allocations and a copy per
  `+`. Now it `xmalloc`s the joined buffer directly and hands it to
  `make_str_owned`. Bench: `strcat 2k` 9.6 → 8.79 ms (~8% n=5 median).
- **`ITER_NEXT` buffer fast path skips the `make_num` round-trip.**
  When the for-loop's iterable is a buffer (homogeneous doubles), the
  yielded element now flows through the stack as an immediate-num slot
  via `vm_push_slot(slot_from_num(...))` instead of allocating a fresh
  `VAL_NUM` per iteration. Bench: `for in range of 50000` 25.1 → 22.1
  ms (~12% n=5 median, T3200). The list-iterable path is unchanged.

### Runtime — closure-cycle collector

- **The env↔fn closure-cycle leak is fixed** (docs/CLOSURE_CYCLE_GC.md).
  Escaping closures — `define inner ... return inner`, counters,
  per-iteration handler closures, method dicts — are now reclaimed, both
  mid-run (registry-threshold collections triggered at closure-capture
  time, zero cost on the dispatch hot paths) and at exit. A
  100k-iteration closure-churn loop runs ~40% faster with peak RSS down
  from ~124 MB to ~4 MB; long-running programs that build closures over
  time no longer grow without bound.
- **`Env` lifetime is an honest refcount.** `env_refcount` now counts
  every owner: the creating frame or C caller, closures, child envs (the
  `parent` link is an owned edge), and a chunk's parked recycled call
  env. `env_free`'s captured-gated semantics are replaced by plain
  `env_incref`/`env_decref`; loop-scope envs move the frame's ref
  explicitly. This also fixes latent leaks on early `return` from inside
  a loop scope and makes the env-recycling parent compare
  dangling-pointer-free.
- **Exit teardown reclaims global-scope value cycles** too (e.g. a list
  appended to itself), via a pinned snapshot of global bindings before
  the final collection. `import` module envs are released when the last
  closure defined in them dies (previously leaked unconditionally).
- The collector is conservative by construction: roots are derived from
  refcounts (any uncounted holder makes a node a root), and an
  accounting mismatch aborts the collection — the failure mode is a
  leak, never a use-after-free. Disabled once `spawn` goes
  multithreaded; spawned programs keep the previous behavior.
- Suite: `tests/test_closure_cycles.eigs` (now 17 checks, incl. dict-
  routed cycles and 500 discarded counters) is gated **strictly**
  leak-clean under ASan — section [87] no longer tolerates a
  LeakSanitizer exit. The suite-wide tolerated-leak tally drops 28 → 13;
  every remaining report is byte-identical to the pre-collector
  baseline (spawn-thread programs + pre-existing non-closure shapes).

### Distribution — macOS release binaries, checksums, stability contract

- The Release workflow now builds and publishes macOS binaries —
  `eigenscript-macos-x86_64` (Intel, JIT enabled) and
  `eigenscript-macos-arm64` (Apple Silicon, interpreter-only until the
  ARM64 JIT exists) — alongside the Linux assets, each leg running the
  full suite against the exact binary it uploads. Releases also gain a
  `CHECKSUMS` file (`sha256sum -c` / `shasum -a 256 -c` verifiable).
- The Makefile's hardened link flags (`-z relro`/`-z now`) are now
  Linux-only: macOS's ld64 rejects them, which silently broke every
  Makefile link target on macOS — `make lsp` most visibly. The macOS CI
  leg now compile-checks the LSP so this can't regress unseen.
- README gains a **Stability** section: the executable spec
  (docs/SPEC.md) is the pre-1.0 compatibility surface — patch releases
  never change documented behavior, minor releases may with a CHANGELOG
  entry, and everything outside the spec is explicitly unstable.
- docs/PACKAGE_DESIGN.md: the package/dependency **design proposal**
  (vendored `eigs_modules/`, git-pinned manifest + lockfile, `--pkg`
  tool, install executes nothing). Nothing implemented; open questions
  listed for decision.

## [0.13.0] — 2026-06-12

A language-features release.

### Language — structured errors, stack traces, user modules

- **`throw` preserves the thrown value.** `throw of {"kind": ..., ...}`
  now binds the *dict* (or list, or any value) to the catch variable
  instead of a stringified copy — errors can carry data and be matched
  on fields. Thrown strings and runtime errors bind as strings, exactly
  as before; a runtime error raised while a structured value is in
  flight supersedes it. (`tests/test_trycatch.eigs` 13 → 23 checks.)
- **Uncaught errors print a stack trace**: every frame between the
  failure and the top level, innermost first, with function name and
  line (`at inner (line 6)` / `at <module> (line 9)`), resolved from
  each frame's saved ip via the chunk line tables. Applies to runtime
  errors and uncaught `throw` alike; stderr-only, so program output
  and the error-message contract are unchanged.
- **`import` loads user modules.** When `lib/<name>.eigs` doesn't
  exist, `import name` falls back to `<name>.eigs` resolved relative
  to the script (then the other standard locations) — same namespaced
  dict binding, nothing in global scope. The not-found error now names
  both tried paths. (`tests/test_import.eigs` 12 → 17 checks.)
- docs/SPEC.md: `import` documented for the first time (executed
  examples, stdlib + user module), structured-throw and stack-trace
  sections added; new `examples/errors/uncaught_with_trace.eigs`.

### Tooling — editor support and published docs

- **`editors/vscode/`** — VS Code extension: TextMate grammar (keywords,
  interrogatives, predicates, f-string interpolation, definitions and
  call sites, `|>`/`=>`), comment toggling, bracket/auto-indent rules.
  Symlink into `~/.vscode/extensions/` or package with vsce.
- **`editors/vim/`** — Vim/Neovim syntax + ftdetect for `.eigs`.
- **`.gitattributes`** maps `.eigs` to Python highlighting on github.com
  until a Linguist grammar is upstreamed.
- **Docs site** — `.github/workflows/pages.yml` publishes `docs/` via
  GitHub Pages (Jekyll, relative links resolved; the workflow provisions
  Pages itself on first run). Requires a public repo or paid plan.
- `VERSION` bumped to 0.13.0. Releases: push a `v*` tag **or** dispatch
  the Release workflow — it creates the tag itself (version defaults to
  the VERSION file) and builds in the same run, since environments
  exist that can't push tags and GITHUB_TOKEN-pushed tags don't
  retrigger workflows.
- Doc-example checker runs each example with cwd = its own script dir
  (the macOS Python tempdir is /var/folders/..., not /tmp — examples
  must not assume either).

### Fix — buffer index-assignment kept only the integer part

`b[i] is 1.5` stored `1.0` while `buf_set of [b, i, 1.5]` stored `1.5`:
all four interpreter INDEX_SET arms carried an `(int)` cast on the
stored value, and the JIT's inline buffer store round-tripped through
`cvttsd2si`/`cvtsi2sd` — even though `buffer.data` is `double*` and
nothing documents truncation. Found while writing the executable spec
(its buffer example produced the wrong output). Index-assignment now
stores the full double in the interpreter and the JIT alike, agreeing
with `buf_set`. Regression checks in `test_builtin_indirect.eigs`
(fraction kept, agrees with buf_set, negative fractions) and
`test_jit_paths.eigs` (fractional stores through the hot inline path).

### Docs — executable spec, comparison guide, error corpus

The "AI-legibility" round: documentation a human or a model can trust
because the suite executes it.

- **`docs/SPEC.md`** — canonical spec: every construct with a runnable
  example and its exact output. 38 example/output pairs are executed by
  the new `tests/test_doc_examples.py` (suite section [89]) and must
  match byte-for-byte, so the spec cannot drift from the
  implementation.
- **`docs/COMPARISON.md`** — EigenScript next to Python/JS/Rust/Lisp
  with a porting checklist and before/after transformations; the
  EigenScript halves are suite-verified the same way (11 pairs).
- **`examples/errors/`** — nine programs that fail on purpose, each
  declaring its expected message in an `# expect-error:` header,
  enforced by `tests/test_error_examples.sh` (section [90]).
- **`docs/README.md`** — documentation map; README points at it and at
  the spec.

### LSP — parse-error diagnostics now actually appear

The language server advertised `publishDiagnostics` but never sent a
non-empty one: `send_diagnostics` gated on `g_error_msg`, which the
parser/lexer never populate on a syntax error (they only print to
stderr). So the editor's headline feature — red squiggles on bad
syntax — was dead. The lexer/parser now record the first syntax error
of each tokenize+parse pass (line + message) via a new additive
`eigs_record_first_error` hook — reset at the top of `tokenize()`,
captured at the common sites (unexpected character, unterminated
string, indentation mismatch, `expected X got Y`) — and the LSP turns
it into a diagnostic at the correct 0-based line. The CLI's stderr
output is byte-for-byte unchanged (the capture is purely additive).
New `tests/test_lsp.py` / `test_lsp.sh` (suite section [88], 23 checks)
drive the server over real Content-Length-framed JSON-RPC and assert
initialize capabilities, the now-working diagnostics (clean → none;
syntax errors → right line + message; `didChange` clears them),
completion, hover, definition, references, and `shutdown`/`exit` — the
LSP was previously only compile-checked.

### Closure-cycle leak — investigated; scoped as a reviewed project

A captured `Env` and the closure bound within it form a refcount cycle
the runtime can't reclaim. Confirmed it **accumulates** (~12
allocations per escaping closure; 500 → ~6,000 leaked), correcting
earlier text that implied a bounded exit-time blip. Investigated all
three fix options and recorded why none is a safe drive-by patch
(`docs/CLOSURE_CYCLE_GC.md`): weak self-binding either way introduces
use-after-free (non-escaping recursion / escaping returns), and a
collector is blocked by `Env` having no uniform refcount (trial
deletion) or needing intrusive all-objects registries plus complete
root enumeration (mark-sweep) — a change whose failure mode is memory
corruption, so it belongs in a dedicated reviewed effort, not here.
`tests/test_closure_cycles.eigs` (section [87], 14 checks) pins the
functional correctness of every cycle shape and the non-leaking
invariants (self-referential containers, non-escaping recursion stay
clean) so a regression toward UAF or a wider leak is caught. The
re-examined "dead code" candidates (`tok_type_name`, uncalled `env_*`
helpers, unreachable lint rules) are defensive or public-header API —
left in place rather than churned to game a coverage number.

### Testing & CI — coverage-gap closure

A gcov pass over the suite (`docs/TEST_COVERAGE_ANALYSIS.md`) drove a
round of test, runner, build, and runtime fixes:

- **Lambda closures no longer leak their defining env.** `OP_CLOSURE`
  bumped `env_refcount` *and* `make_fn` took the fn's own ref — the
  extra count had no owner, so a call env that created any closure
  could never drop to zero. A fn returned as a lambda (no self-binding)
  now frees its env when the last fn ref dies. The remaining known leak
  is the env↔fn cycle of `define`-bound closures (`define inner` lives
  *in* the env that `inner` captures) — refcounting alone cannot
  reclaim it; the suite runner tolerates LeakSanitizer-only nonzero
  exits and tallies them in the final summary.
- **Suite sections gate on exit codes** (`rc_ok` / `check_eigs_suite`
  in `run_all_tests.sh`): a crash after correct output now fails the
  section instead of slipping past the marker grep (previously only
  check [71] asserted rc).
- **Wired in orphaned tests**: `test_fmt.sh` (14 checks) and
  `test_lint.sh` (10, plus a cwd-bitrot fix) — fmt.c/lint.c were at 0%
  line coverage; 28 orphaned `.eigs` suites ([85]); compound
  dot-assignment (`d.k += v`, `items[i].f += v`) which had zero
  coverage of its clone_ast desugaring.
- **New suites**: `test_jit_paths.eigs` ([82], checksummed coverage of
  the Stage-5 fused opcodes, inline-IC slow paths, OSR, and JIT
  helpers, with an EIGS_JIT_STATS gate so it can't silently pass
  interpreted), `test_walker_matrix.eigs` ([83], closure capture per
  AST node kind — the #156 bug class), `test_builtin_indirect.eigs`
  ([84], lowered-opcode vs C-builtin agreement for `dispatch` and the
  bench-only buffer builtins).
- **CI**: new `extensions` job builds `make http` and runs the suite
  against it (the probe-gated HTTP/model sections never executed in CI
  before), compile-checks `make gfx` and the LSP, and runs
  `make jit-smoke`.
- **`make lsp` fixed**: the hand-picked source list predated the
  bytecode VM (80 unresolved symbols); it now links the full runtime
  minus `main.c`, with the missing `g_exe_dir` / `g_load_env`
  definitions added to `eigenlsp.c`.
- `make_fn` dropped its dead `body`/`body_count` params (AST bodies
  died with the tree-walking evaluator); `clone_ast` survives as the
  parser-internal compound-dot-assign desugar helper.

Round 2 (residual gaps from `docs/TEST_COVERAGE_ANALYSIS.md`):

- **`make fuzz` fixed** — same bitrot as the LSP: FUZZ_SOURCES predated
  the bytecode VM and the harness called the deleted `eval_node`. It
  now links the full runtime minus main.c and drives tokenize → parse
  → compile_ast → vm_execute; 44 curated adversarial cases run under
  ASan in the `extensions` CI job on every push.
- **ext_db executes in CI** — new `database` job: postgres:16 service
  container, `make full`, suite with `DATABASE_URL`. `test_db.eigs`
  gained a live-connection-gated table round-trip (DB09–DB15:
  CREATE / parameterized INSERT / COUNT / parameterized SELECT /
  multi-row `db_query_json` / malformed-SQL error).
- **New suites/checks**: `test_corpus.eigs` ([86], 25 checks —
  `build_corpus` + the `tok_base_string` detokenizer table, both 0%
  before; lexer.c 71→92%), ext_store list-valued fields +
  corrupt-header rejects (`store_json_parse_array` was 0%;
  test_store 14→22), JSON escape branches JH32–JH43 (`\n \r \t \/ \`
  + multi-byte `\uXXXX`, only ASCII `\u` ran before), lint
  fn-def-shadow / fn-unreachable / feature-rich-clean-walk
  (lint.c 50→81%), and hot interrogated/captured-name assignment in
  `test_jit_paths.eigs` (`jit_helper_set_fn_name_local`, the last 0%
  JIT helper, → 69%).
- Findings for future cleanup: the lint empty-block and
  is-in-condition rules are unreachable (parser rejects those inputs
  first), and eigenscript.c's residual ~25% is mostly `tok_type_name`
  plus legacy env API variants the VM no longer calls.
- Suite: 1704 checks (release + ASan; 27 tallied closure-cycle
  leak-exits), 1766 on the full build with live postgres.

### Fixes

- **#159 — `proc_read_buf` for binary-safe child stdout; `proc_read_line`
  / `proc_write` return partials instead of dropping them.** Three
  related robustness fixes in the 0.13.0 streaming-subprocess surface:
  - `proc_read` reads into a heap buffer, writes a trailing NUL, and
    returns a `VAL_STR` — an embedded NUL in the child's output
    silently truncated the result at the first one. The natural use
    of `proc_read` (as opposed to `_line`) is bulk/binary output,
    where NUL is just a byte. New `proc_read_buf of [fd, max]`
    mirrors `read_bytes_buf`: returns a `VAL_BUFFER` so every byte
    survives, indexable like any buffer; `null` on EOF; same 10 MB
    cap. `proc_read` is now documented as text-only.
  - `proc_read_line` returned `null` when a mid-stream `read(2)`
    failed, dropping any partial line already buffered. The
    documented contract reserves `null` for "EOF with empty buffer";
    a partial-then-error now returns the partial (mirrors the
    EOF-with-partial path just below).
  - `proc_write` returned `-1` after a **partial** write hit an error
    (e.g. EPIPE mid-stream). Within the contract, but a caller that
    retries on `-1` then double-sends the delivered prefix. Now
    returns the partial byte count; `-1` is reserved for the
    nothing-was-written case (like `write(2)` itself).
  Regression in `tests/test_proc_stream.eigs` (30 → 39 checks):
  `printf %b` with an embedded `\0` round-trips through
  `proc_read_buf` byte-for-byte (15a–15f), `proc_read` still
  NUL-truncates (16a), and `proc_read_buf` returns `null` on EOF
  (17a, 17b).
- **#158 — defaults fire for every unsupplied defaulted slot, regardless
  of `argc`.** The OP_CALL binding logic in `src/vm.c` gated the
  null-placeholder bind-then-OP_DEFAULT_PARAM tail on `(argc >=
  first_default) && (argc < param_count)`. That meant an underfed call
  *below* `first_default` skipped the entire defaulted tail — on
  `define f(a, b, c is 1)`, `f of 5` bound `a=5, b=null, c=null`
  instead of `a=5, b=null, c=1`. The DISPATCH path (single-arg method
  call) had the analog: the `first_default <= 1` gate left slot 1+
  unbound whenever `first_default > 1`. Fix: drop the lower-bound `argc
  >= first_default` requirement at both `src/vm.c` binding sites and
  the OP_DISPATCH path. Tail slots `[argc, param_count)` always get a
  null placeholder when the chunk has defaults; OP_DEFAULT_PARAM then
  fills the defaulted ones (non-defaulted underfed slots stay null,
  matching the no-default underfed semantics). The #154 contract
  callout that documented the now-fixed argc<first_default subtlety is
  rewritten — the docs and behavior now agree. Regression in
  `tests/test_default_params.eigs` (+7 checks 9a–9g: underfed-mid,
  underfed-empty, two-default-trailing combinations) and
  `tests/test_call_semantics.eigs` (the `mpd2 of []` shape flipped to
  `[null, 100]`; added `mpd3` underfed scalar/empty checks).
- **#157 — destructure pattern parser: specific errors, no silent fallthrough.**
  The 0.13.0 destructuring lookahead in `src/parser.c` filled a fixed
  `names_tmp[64]` buffer and silently `p->pos = saved`-restored the
  position on any mismatch (>64 names, trailing comma, non-ident
  target). The user then hit whatever the list-literal expression
  parser said about the same tokens — usually "1 parse error(s)" with
  no hint that they'd written something close to a destructure.
  Fix: before consuming, bracket-count the lookahead to find the
  matching `]` and check if the following token is `is`. If so, commit
  to destructure parsing and emit pattern-specific errors:
  - `[a, b,] is rhs` → "trailing comma in destructuring pattern"
  - `[a[0], b] is rhs` / `[a.x, b] is rhs` → "destructuring pattern
    requires identifiers (index/field targets like a[0] or a.x are not
    supported)"
  - 65+ name pattern → "destructuring pattern exceeds 64 names"
  List-literal expression statements that don't end in `] is` still
  parse normally (the scan returns "not a destructure"). Regression in
  `tests/run_all_tests.sh` (slot [16/16] Error Messages, +3 checks
  EM21/EM22/EM23).
- **#154 — docs: unflagged semantic change `g of []` on multi-param fn.**
  0.13.0's default-params commit lowered `f of []` to an argc=0 call
  so an all-default function can be called with no args. The single-
  param non-defaulted case was preserved by a compile-time special
  case (`one of []` still binds the param to the empty list), but
  multi-param functions silently changed: `g of []` on
  `define g(a, b)` now binds `a=null, b=null` (was `a=[], b=null` in
  0.12.0). The new behavior is the cleaner reading of the contract
  ("missing parameters are `null`"), but it's still an observable
  shift that wasn't flagged. Fix: LANGUAGE_CONTRACT.md default-params
  section now spells out the change, including the subtle case that
  defaulted multi-param fns *also* get all-null (because defaults fire
  only when `argc >= first_default`, and argc=0 < 1 = first_default).
  A grep of the suite and Tidepool turned up no multi-param-takes-
  empty-list call sites, so no code change needed. Regression in
  `tests/test_call_semantics.eigs` (12 → 16): pin down the multi-param
  `[null, null]` shape, the 1-param-preserves-empty-list shape, the
  defaulted-1-param fires its default, and the defaulted-multi-param
  all-null (argc<first_default) edge.
- **#153 — docs: contract spells out the `f of [x]` non-spread rule.**
  `docs/LANGUAGE_CONTRACT.md` previously promised "if `f` has two or
  more parameters and `X` is a list, the elements are spread", which
  read like a length-agnostic rule. The compiler only spreads literal
  lists at `count > 1` (`src/compiler.c` call lowering), so `f of [x]`
  always binds the one-element list as a single argument regardless of
  callee arity. With 0.13.0 default parameters, "call a defaulted
  multi-param fn with one arg" became a mainstream pattern and started
  hitting this surprise — notably the recursive form `fib of [n - 1]`
  the moment you add a defaulted `memo`. Fix: the call-spread section
  now states "literal list of length ≥ 2 spreads; length-1 binds the
  whole list", and the default-params section calls out the footgun
  with the `fib` example and the `f of (x)` paren-form workaround.
  Behavior unchanged; this is a docs-only sharpening. Regression in
  `tests/test_call_semantics.eigs` (8 → 12 checks): pin down the
  multi-param + 1-elem-list, paren-form spread, default-fires-with-paren,
  and `fib of (n - 1)` recursion shape.
- **#152 — `audio_play_loop` hard caps loops + clip-aware byte budget.**
  `builtin_audio_play_loop` cast its `double` loops argument to `int`
  without bounds-checking; NaN, `+inf`, or any value above `INT_MAX` was
  undefined behavior, and even a well-formed huge `int` (or a modest
  count over a multi-second clip) would queue gigabytes into SDL's audio
  ring in a single call. `SDL_QueueAudio` copies the buffer each time,
  so one bad call could OOM the process or stall it in a copy loop. Fix:
  reject NaN and any value outside `[1, 10000]` before the cast (hard
  ceiling, documented in CLAUDE.md), and additionally reject any call
  whose total queued bytes would exceed a 256 MiB budget
  (`loops * samples * sizeof(int16_t)`). A 5-second 44100Hz clip caps
  at ~593 loops; the typical short-clip case (a few hundred ms) still
  hits the 10000-loop ceiling. Regression in `tests/test_audio.eigs`
  (slot [62], 20 → 24): covers `loops>10000`, `1e20` (cast UB sentinel),
  byte-budget rejection on a 5s clip, and `loops=10000` at the ceiling
  still succeeding.
- **#151 — `recv_timeout` clamps `ms` before the `(long)` cast.**
  `builtin_recv_timeout` cast a `double` ms argument directly to `long`
  when computing the deadline; NaN, `+inf`, or any value above `LONG_MAX`
  is undefined behavior in C and in practice produced a garbage deadline
  that fired immediately (spurious instant timeout) or waited
  essentially forever. Fix: sanitize `ms` first — NaN degenerates to 0
  (try_recv), negatives degenerate to 0, anything above ~one year of
  ms (3.15e10) clamps to that ceiling, which keeps the integer
  arithmetic well below `LONG_MAX` on every supported `time_t`.
  Related hardening: channel condvars now use `CLOCK_MONOTONIC` via
  `pthread_condattr_setclock`, so `recv_timeout`'s deadline is immune
  to wall-clock steps (NTP, `settimeofday`). Matches `exec_capture`'s
  monotonic discipline. Regression in `tests/test_channel_nb.eigs`
  (slot [77], 22 → 29).
- **#148 — replay boundary for subprocess and concurrency builtins.**
  Ten builtins sit on the wrong side of `EIGS_REPLAY`'s replay-by-tape
  contract: `proc_spawn`, `proc_write`, `proc_read_line`, `proc_read`,
  `proc_close`, `proc_wait`, `exec_capture`, `recv`, `try_recv`,
  `recv_timeout`. Their return values do not pin down the host-side
  causal structure (child PIDs, fd numbers, kernel scheduling), so
  replaying them — even with `TRACE_NONDET_TAKE` — would let a recorded
  script re-execute real side effects against a tape that cannot
  re-create the world it ran in (verified: replaying a proc program
  forked real children). Fix: each of the ten builtins now checks
  `g_replay_enabled` first and raises a catchable runtime error
  (`"<fn>: not replayable under EIGS_REPLAY (subprocess/concurrency
  boundary; see docs/TRACE.md)"`). Boundary is documented in a new
  "Non-Replayable Builtins" section of `docs/TRACE.md`. Regression in
  `tests/test_replay.sh` (two new cases).
- **#149 — `FD_CLOEXEC` on `proc_spawn` and `exec_capture` pipe fds.**
  The four pipe ends in `proc_spawn` (`in_pipe[0/1]`, `out_pipe[0/1]`)
  and the two in `exec_capture` (`pipefd[0/1]`) were left without
  `FD_CLOEXEC` after `pipe(2)`, so a subsequent `proc_spawn` /
  `exec_capture` child inherited the parent-side fds of every prior
  spawn — a long-running interpreter accumulating live procs would leak
  growing fd tables into each new child. Fix: `fcntl(F_SETFD,
  FD_CLOEXEC)` on every pipe end right after `pipe()`. The child's
  `dup2` into `STDIN_FILENO`/`STDOUT_FILENO` clears `FD_CLOEXEC` on the
  destination, so the child's own stdio still survives `execvp`.
  Regression in `tests/test_proc_stream.eigs` (case 13: spawn cat, then
  `exec_capture` a `sh -c` checker that asserts the pipe fds are absent
  from the new child's `/proc/self/fd`).
- **#150 — `exec_capture` child resets `SIGPIPE` to `SIG_DFL`.**
  `proc_spawn` installs a process-wide `SIGPIPE = SIG_IGN` once (so
  the EigenScript parent gets `EPIPE` on write instead of dying), and
  that disposition survives `fork`. After at least one `proc_spawn`,
  every `exec_capture` child inherits `SIG_IGN`, so any subprocess
  pipeline that relies on `SIGPIPE` to drain (`yes | head -1`,
  `cat | head`, GNU `tar | cmd`) hangs — the upstream producer fills
  its pipe buffer instead of dying when the downstream reader exits.
  Fix: `signal(SIGPIPE, SIG_DFL)` in the `exec_capture` child block
  between `fork` and `execvp`, mirroring `proc_spawn`. Regression in
  `tests/test_proc_stream.eigs` (case 14: `yes | head -n 1` under
  `exec_capture` with a 5s timeout — passes promptly when SIGPIPE is
  reset, would hit the timeout otherwise).
- **#155 — `frame->call_argc` initialized on `vm_run`'s base frame.**
  Every entry path that runs a user function through `vm_execute`
  (`spawn`, `sort_by` / tensor gradient callbacks via `call_eigs_fn`,
  `dispatch`, HTTP handlers, module-level) leaves the base frame's
  `call_argc` reading whatever stale value the last occupant of that
  depth left behind — or zero on a fresh thread. `OP_DEFAULT_PARAM`
  compared against that garbage, so a 0.13.0 default could fire over
  a slot the caller did supply. Most reproducible on a fresh thread:
  `spawn of [worker(a, b is 100), 1, 2]` was returning 101 instead of
  3. Fix: set `frame->call_argc = chunk->param_count` in the base-frame
  init — the C caller has already bound every param, so no default
  should re-fire. Regression in `tests/test_default_params.eigs`
  (slot [72], 16 → 21).
- **#156 — AST pre-pass walkers handle `AST_SLICE` and
  `AST_LIST_PATTERN_ASSIGN`.** All five compiler walkers
  (`collect_referenced_names`, `collect_referenced_names_skip`,
  `scan_for_captures`, `scan_for_interrogated`,
  `collect_module_names_walk`) fell through `default: break` on the
  two 0.13.0 node types, so a closure that touched an outer local
  only through a slice (`data[1:3]`) or a destructure RHS
  (`[m, n] is pair`) slot-promoted the outer and read `null`, and a
  module-level destructure (`[gx, gy] is [100, 200]`) was invisible
  to module-name collection so writes inside functions silently
  created locals instead of updating the globals. Fix: register
  destructure target names and recurse into RHS / slice
  (target, start, end) in every walker. Regressions in
  `tests/test_slicing.eigs` (slot [76], 46 → 48) and
  `tests/test_destructuring.eigs` (slot [74], 26 → 28).

### Audio — `audio_play_loop` (finite-count loop playback)

`audio_play_loop of [samples, loops]` queues a sample list `loops`
times in a single call (finite, `loops >= 1`). Saves N round-trips
through the workaround pattern of polling `audio_queue_size` each
frame to refill an ambient loop. Returns total samples queued
(`len of samples * loops`), or `0` on bad args / closed device.

`loops == -1` (continuous infinite loop) is intentionally rejected
for now — that needs a background refill mechanism and is a
separate ship. The proper way to choose between the two: pick
`audio_play_loop` for any finite repetition (game ambient that
plays N times, sound cue repeated, music loop that ends with the
level); pick the existing poll-and-refill workaround for genuinely
infinite cases until the infinite variant lands.

Wire-up: new `builtin_audio_play_loop` in `src/ext_gfx.c` next to
`builtin_audio_play`, registered alongside it. Single int16
conversion pass, then N `SDL_QueueAudio` calls with the same
buffer — keeps memory flat regardless of `loops` count (vs. a
single-call `n * loops` allocation that would balloon for long
clips).

Test: 6 new checks appended to `tests/test_audio.eigs` (suite slot
[62], 14 → 20), gated on a successful `audio_open` so the
non-gfx builds and headless-CI machines fall through to skip-asserts.
SDL2's `dummy` audio driver is enough to exercise the success path
locally (`SDL_AUDIODRIVER=dummy`). Closes Tidepool `GAPS.md`
GAP-002 finite-count form.

Note also: GAP-001 (`audio_sweep`) was already shipped (predates
this cycle); Tidepool's GAPS.md just hadn't been updated.

### Language — `spawn` with multiple args

`spawn of [fn, arg1, arg2, ...]` now passes N positional arguments
to the spawned function, not just one. Bare `spawn of fn` (no args)
and the existing `spawn of [fn, arg]` (one arg) keep working
verbatim. Missing trailing params bind to `null`; extra args are
ignored — same arity-tolerant stance EigenScript already uses for
regular calls. Args are shared by reference, not deep-copied,
matching the channel model already in place (`docs/BUILTINS.md`
thread-safety note: mutable containers shouldn't be mutated
concurrently from both sides; transfer ownership or send immutable
values).

Wire-up: `ThreadHandle` swaps its single `fn_arg: Value*` slot for
`fn_args: Value**` + `fn_arg_count: int`; `builtin_spawn` incref's
every list element 1..N (element 0 is the fn) into a heap-allocated
arg array; `thread_entry` binds `args[0..bind_n)` to params via
`env_set_local`, then fills the remaining params with `null` via
`env_set_local_owned`; `builtin_thread_join` decref's every arg
and frees the array on cleanup. For `VAL_BUILTIN` callees the
1-arg path stays `fn(args[0])` (zero churn for existing one-shots
like `spawn of [my_builtin, x]`); 0-arg becomes `fn(null)`; N-arg
packs into a list to match how EigenScript surfaces multi-arg
calls to builtins everywhere else.

Test: `tests/test_spawn_args.eigs` (22 checks across 0/1/2/3-arg
forms, underfill / overfill, heterogeneous types, concurrent
spawns with no cross-talk, shared-by-ref semantics, closure capture
+ extra args, and the non-function-first-arg error path; suite slot
[78]). Fix for Tidepool `GAPS.md` GAP-006.

### Language — non-blocking channel recv (`recv_timeout`)

`recv_timeout of [channel, ms]` joins `try_recv` as the second
non-blocking option for game loops, UI threads, and any caller that
can't afford `recv`'s unbounded park. Returns the value if one
arrives — or is already buffered — before the deadline; returns
`null` on timeout or on close-while-waiting. Fractional `ms` is
honored (ns precision via `pthread_cond_timedwait` on
`CLOCK_REALTIME`); negative `ms` degenerates to a `try_recv`.

Wire-up: new `builtin_recv_timeout` in `src/builtins.c` next to
`builtin_recv` / `builtin_try_recv`, registered alongside them in the
builtins env. Deadline is computed by adding `ms` to a
`clock_gettime(CLOCK_REALTIME, ...)` snapshot, then the existing
`while (count == 0 && !closed && rc == 0)` drain pattern uses
`pthread_cond_timedwait` instead of `pthread_cond_wait` — so it
honors spurious wakeups, close broadcasts (channel's
`pthread_cond_broadcast(&not_empty)` already wakes the waiter), and
the deadline uniformly. No new state on the `Channel` struct.

`try_recv` was already shipped earlier but had zero suite coverage;
the new `tests/test_channel_nb.eigs` closes that hole alongside the
`recv_timeout` paths (22 checks across empty / buffered / FIFO /
post-close drain / negative-ms degeneration / cross-thread arrival /
close-while-waiting / error paths; suite slot [77]). Fix for
Tidepool `GAPS.md` GAP-005.

### Language — slicing

`a[start:end]` is now a real expression form, half-open, with `[:]`,
`[start:]`, `[:end]`, and `[:]` defaults and negative bounds resolved
against length first. Applies to lists, strings, and buffers — the
same three sequence types that accept `a[i]`. The slice is always an
**independent copy**: mutating `b = a[1:4]; b[0] is 999` leaves `a`
untouched, matching the same "values, not views" stance used by the
rest of the language.

Bounds-check is strict, not clamping: `0 <= start <= end <= len`
(note `<=` on the upper end, since positions sit between elements —
`a[len:]` is a legal empty slice but `a[len]` raises). Too-positive
upper bounds, inverted ranges (`a[3:1]`), too-negative starts
(`a[-99:]`), and non-integer / non-sequence operands all raise, same
philosophy as single indexing — same surfacing of sloppy arithmetic
that 0.13.0 already does for `a[2.9999998]`.

Wire-up: new AST node `AST_SLICE { target, start, end }` (NULL bound
= omitted = default), new opcode `OP_SLICE_GET` (pops 3, pushes 1).
Parser factors a `parse_subscript_suffix` helper out of the seven
inline `[...]` postfix sites in `parser.c` so list-vs-slice
disambiguation happens in one place; statement-level destructuring
(`[a, b] is rhs`) is unaffected because that lookahead runs only
when `[` opens a fresh statement. JIT scanner needs no change — its
default-else stops on any unknown opcode, so a new bytecode just
falls back to the interpreter for now. Test:
`tests/test_slicing.eigs` (46 checks across 18 sections, suite slot
[76]).

### Language — streaming subprocess I/O

Six new builtins for talking to a child process over time, sibling to
`exec_capture`'s all-at-once form. `proc_spawn of [argv...]` returns
`[pid, in_fd, out_fd]` (or `[-1,-1,-1]` on failure) for a fork+execvp
child with stdin/stdout connected to anonymous pipes; `proc_write`,
`proc_read_line`, and `proc_read` move bytes through those pipes with
raw `read(2)`/`write(2)` (no parent-side stdio buffering — line
streaming relies on the child not block-buffering its stdout, hence
the `stdbuf -oL` note in the contract); `proc_close` is an idempotent
`close(2)`; `proc_wait` blocks on `waitpid` and returns the exit code
(or `128+sig` if killed by a signal).

SIGPIPE is set to `SIG_IGN` process-wide on first spawn so a writing
parent gets `EPIPE` from `proc_write` instead of dying; the child
resets SIGPIPE to `SIG_DFL` post-fork so it keeps conventional Unix
broken-pipe semantics. No GC integration on the handle for v1:
callers explicitly `proc_close` both fds and `proc_wait` the pid.
Test: `tests/test_proc_stream.eigs` (25 checks, suite slot [75]).

### Language — destructuring assignment

`[a, b, c] is rhs` evaluates `rhs` once, requires it to be a list of
exactly 3 elements, and binds the three names. Length mismatch and
non-list RHS both raise; matches the strict bounds-check stance the
language already uses for indexing. Swap is the natural consequence:
`[a, b] is [b, a]` builds the RHS list first, so both reads happen
before either write.

Wire-up: AST `AST_LIST_PATTERN_ASSIGN { names[], name_hashes[],
expr }`; new opcode `OP_DESTRUCTURE_UNPACK <n:u16>` that pops a list,
validates length, then pushes elements in reverse so element 0 ends
up at TOS. Compiler factors the per-name OBSERVE+SET emission out of
AST_ASSIGN into a reusable `emit_assign_for_tos` helper (same slot/
captured/global resolution rules) and the destructure case calls it
N times with `OP_POP` between each to expose the next element.
Parser recognises `[ IDENT (, IDENT)* ] is` at statement start via
lookahead with save/restore, so list-literal expressions still parse
as expressions. V1 supports plain identifier targets only — nested
patterns, index/field targets, and rest patterns are deliberately
deferred. Test: `tests/test_destructuring.eigs` (26 checks, suite
slot [74]).

### Language — negative indexing

`a[-1]` is now the last element of `a`, `a[-2]` the second-to-last,
through `a[-len of a]` which is the first. Applies uniformly to
lists, strings, and buffers (the three sequence types `a[i]` accepts
today). Resolution is `i + len` *before* the bounds check, so the
valid input range becomes `[-len, len)`; too-negative indices raise
the same out-of-range error as too-positive ones. Error messages
report the original user-written index (`a[-99]` on len 5 raises
"index -99 out of range" — not the post-resolution value).

Wire-up: new `vm_index_resolve(&i, len)` helper in vm.c sits between
`vm_index_is_int` and the bounds check; all 14 index sites
(OP_INDEX_GET / OP_INDEX_SET / jit_helper_index_get /
jit_helper_index_set, slot fast paths and slow paths, list+string+
buffer arms) route through it. JIT inline INDEX_SET buffer fast path
needs no change: its unsigned-compare bounds-check already bails to
the helper on negative indices, and the helper now resolves them.
Test: `tests/test_negative_index.eigs` (19 checks including
JIT-loop coverage, suite slot [73]).

### Language — default parameter values

`define f(a, b is expr) as: ...` — trailing parameters can carry
default expressions. When the caller omits an argument the default
is evaluated *at call time* against the live environment + the
already-bound earlier parameters, so defaults can reference earlier
params (`define pair(a, b is a * 2)`) and capture an outer name
freshly per call (`define scale(x, k is multiplier)` re-reads
`multiplier`). Defaults are trailing-only — a required parameter
after a defaulted one is a parse error.

Explicit `null` is a real argument and **does not** trigger the
default. To call with zero args on a single-parameter function,
pass the empty list literal: `f of []` lowers to an argc=0 call.
Lambdas (`->` arrows, `lambda` blocks) do not accept defaults.

Wire-up: AST `func` gains `param_defaults[]` + `first_default`;
`EigsChunk` gains `first_default`; new opcode
`OP_DEFAULT_PARAM [slot:16][skip_off:16]` runs at function entry
and jumps over the per-slot default-eval prologue when
`frame->call_argc > slot`. The interpreter and the JIT helper-call
path bind null placeholders for `[argc..param_count)` so the
default prologue is reachable. Per-chunk env recycling is
unaffected — its `argc < param_count` reject already routes
defaulted calls through `env_new`. Test:
`tests/test_default_params.eigs` (16 checks, wired as suite slot
[72]).

## [0.12.0] — 2026-06-10

A JIT performance release. Stage 5 (a–i) lands the inline fast-path
matrix — INDEX_SET, EnvIC name get/set, dict-dot via 2-way inline
cache, tracked-num arith/compare operands, native VAL_FN calls inside
thunks, per-loop OSR slots, DOT_SET in-place writes, and per-chunk
call-env recycling. Stage 4v/4w/4x close the bailout coverage chain so
INDEX_SET, LOOP_STALL_CHECK, and SET-name opcodes all compile into
thunks. Compile-gating the temporal history removes the always-on
reversibility tax from non-temporal programs. Cumulative on
bench_dmg_shape: 239 → ~116 ms (2.06×); the JIT now beats
`EIGS_JIT_OFF` by ~45% on it, and cpu_instrs runs at ~5 MHz (target
was 4.19).

### Performance — Stage 5i: per-chunk call-env recycling

A function chunk's env layout is fixed (same param names → same slots
→ same hashes), so a dead call env can be parked on its chunk and the
next call rebinds the param slots in place — no env_new, no per-param
env_hash_insert, no binding_version bump, which also keeps every EnvIC
aimed at the env valid across calls. On bench_dmg_shape, env_new
dropped 500k → 9 per run.

Park gates (any failure falls back to env_free, which keeps its own
freelist): single-threaded only (chunks are shared across spawn
threads); never a loop-scope child env (frame->env must equal
fn_env); not captured by a closure; count must equal the
compiler-known layout — a binding created mid-call (e.g. a new
SET_NAME_LOCAL name, `__loop_exit__`) must NOT resolve in the next
invocation, and an underfed call leaves params unhashed; every param
slot must be name-bound (a single-arg OP_DISPATCH to a multi-param fn
binds only param 0). Take gates: cache parent matches the callee's
closure env and the call fully binds the params. Parked slots are
dropped to null (no value pinning) with assign_counts cleared.

Numbers: 2M-trivial-call probe 147 → 109 ms (−26%), recursive fib(25)
23.5 → 19.4 ms (−17%), bench_dmg_shape ~118 → ~116 ms (small — the
per-call env work was a thin time slice there despite dominating the
call counts). All four return paths (interpreter RETURN/RETURN_NULL,
jit_helper_return/_null) park; all three call sites (CASE(CALL),
jit_helper_call, CASE(DISPATCH)) take.

### Performance — Stage 5h: DOT_SET immediate fast path + 2-way dict cache

bench_dmg_shape 156 → ~118 ms (−24%); cumulative for the 0.12.0 JIT
work, 239 → 118 ms (2.0×). Both fixes came straight out of the
post-5f/5g profile and help the interpreter as well as the JIT
(EIGS_JIT_OFF dmg: 230 → 213 ms):

- **DOT_SET immediate fast path.** `jit_helper_dot_set` and
  CASE(DOT_SET) now take the `dict_set_cached_immediate` route that
  LOCAL_DOT_SET has had since 0.11: an immediate-num write into an
  exclusive untracked num field mutates `data.num` in place. The old
  path materialized every value through `vm_pop` — 2 `make_num` +
  ~1.5 `free_value` per DMG step on `ctx.cycles is …` / `ctx.pc is …`
  (999k of the profile's 1.0M make_num calls).
- **2-way set-associative dict cache** (64 sets × 2 ways; same 128
  entries). Direct mapping had a pathological mode the DMG register
  file hit dead-on: two hot keys on the SAME dict whose hashes collide
  mod the set count ("pc"/"cycles") evicted each other on every
  access — 500k full hash walks per run through the dot_get helpers.
  Insertion shifts the previous insert to way 0, so an alternating
  pair settles with one key per way; the Stage 5d inline probe checks
  both ways (no swapping) so a settled pair stays settled in native
  code too.

### Performance — JIT Stage 5f/5g: native calls + per-loop OSR slots

bench_dmg_shape 212 → ~156 ms (−27%); the JIT now beats the
interpreter by ~33% on this workload where they were previously near
parity. Two structural fixes and one coverage op:

- **5g — per-loop OSR slots.** Diagnosis: a chunk had ONE OSR slot,
  owned forever by whichever loop crossed the back-edge threshold
  first. bench_dmg_shape's 65k-iteration setup loop pinned it, so the
  500k-iteration main loop ran fully interpreted through every prior
  stage. Chunks now carry `jit_osr[4]` — one slot per hot loop header,
  scanned by the JUMP_BACK handler; failed offsets keep their slot so
  they can't retry-storm.
- **5f — native VAL_FN calls inside thunks.** `jit_helper_call` now
  pushes the callee frame and invokes the callee's own thunk directly
  when one exists, so a fully-native callee (RETURN sentinel) returns
  straight into the caller's thunk — the DMG shape `cyc is handler of
  ctx` no longer forces an interpreted tail every iteration.
  Return-code triage: 0 = completed; 1 = not eligible (uncompiled
  callee / non-callable / frame or native-depth cap — interpreter
  re-executes the CALL untouched); 2 = deep bail — the callee's thunk
  exited mid-prefix (guard bail, nested deep bail, or pending error),
  every frame ip is left consistent, and a new `-2` advance sentinel
  tells vm_run's three thunk sites to resync to the current frame and
  interpret on. Native call depth is capped (64) because each nested
  native call recurses the C stack, unlike the interpreter's flat
  frame array; errors inside a native callee force a prompt deep bail
  so CHECK_ERROR unwinds without running arbitrary native caller code.
- **OP_DOT_SET compiles into thunks** (helper running CASE(DOT_SET)
  verbatim) — it was the last unsupported op in the DMG main loop
  (`ctx.cycles is …` on a GET_NAME'd dict).

### Performance — JIT Stage 5e: tracked-num operands in arith/compare

Fixes the "observed counter permanently bails native code" class found
in 5d validation, with the mechanism now precisely diagnosed: it is
CASE(SET_LOCAL)'s in-place branch — a counter assigned once while
observed (`k is 0` before an `unobserved:` block) becomes a tracked
Value, and every later unobserved `SET_LOCAL` of an immediate mutates
that Value in place, so the env slot stays a tracked pointer forever
and every native arith/compare touching it bailed, every iteration.

- ADD/SUB/MUL/DIV/MOD and all six comparisons now accept heap/tracked
  `VAL_NUM` operands via a shared loader: immediate → as before;
  pointer → tag/type guards, `refcount >= 2` (rc==1 routes to the
  interpreter so its NUM_REUSE in-place branch keeps observer-value
  identity exact), then `data.num` through the pointer.
- Operand stack refs drop at commit: a's slot is captured before the
  result store overwrites it; b's slot memory sits just above the new
  TOS. A branched commit on the OR of both operands' tag bits
  (snapshotted in %r8 before the loaders) keeps the imm/imm path at
  its pre-5e two-instruction cost (~3% residual on pure-immediate
  loops from the snapshot+test, traded for the class win).
- Per-op bail trampolines: each template's many guards share one
  rel32 hop to the epilogue, so the 256-slot patch budget now scales
  to arbitrarily arith-dense chunks.
- The JIT SET_LOCAL template now mirrors the interpreter's in-place
  branch exactly (imm TOS over an exclusive untracked num rewrites
  data.num). This is correctness, not just speed: the swap path would
  free a Value that `g_last_observer` can still point at — the
  interpreter never frees it in this situation precisely because of
  that branch.

Poisoned-counter dict loop 141→105 ms (−26%); bench_idxset 24.6→22.2
ms (−10%, its `fill` counter was poisoned); observed buffer-fill probe
−13%. bench_dmg_shape is now capped by user-fn OP_CALL bails forcing
an interpreted tail every iteration — recorded in ROADMAP.md as the
next JIT item.

### Performance — JIT Stage 5d: inline dict-dot fast paths

`LOCAL_DOT_GET` / `LOCAL_DOT_SET` (the `c.a is c.a + 1` shape — DMG
register access) now inline their hot paths in thunks instead of
paying the helper-call ABI:

- shared probe: fn_env slot is a heap `VAL_DICT`, dict-cache entry
  match (`(h ^ ptr) & mask` with the hash baked at compile time, the
  TLS cache reached via the g_vm tpoff delta), interned-key pointer
  equality;
- GET pushes `v->data.num`'s raw bits when the field is an untracked
  num — that IS the immediate slot encoding, so no refcounts and no
  allocation;
- SET mirrors `dict_set_cached_immediate`: in-place `data.num`
  overwrite when the existing field is an exclusive untracked num and
  TOS is an immediate.

Cache misses, strcmp-equal keys, non-num/observed fields, and non-dict
targets fall back to the Stage 4m/4q-d helpers, which repopulate the
dict cache for the next iteration. New `EigsJitLayout` fields expose
the vm.c-private dict cache (tpoff, entry size/offsets, mask).

Isolated dict-RMW loop (2M iterations, fully unobserved): 65 → 45 ms
(−31%). Suite green, zero JIT bailouts on the benchmarks.

### Found — observer-tracked numbers permanently bail native code

Diagnosed while validating 5d: a variable assigned even once while
observed (e.g. `k is 0` before an `unobserved:` block) is promoted to
a TRACKED-num Value, and the interpreter's NUM_REUSE in-place
arithmetic keeps that same tracked Value alive forever — so every
native arith/compare touching it guard-fails, every iteration. The
thunk enters, bails at the first comparison, and the loop body runs
interpreted. This is the structural cap on `bench_dmg_shape`'s
top-level loop (`steps`, `pc` are tracked) and likely on any
"setup, then hot loop" program. Recorded in ROADMAP.md as the next
JIT item: tracked-num operand support in the arith/compare templates
(read `data.num` through the pointer; the write side must respect
observer semantics).

### Performance — JIT Stage 5: inline fast paths (5a/5b/5c)

The Stage 4 coverage chain left hot loops compiling to single thunks
whose every GET_NAME / SET_NAME / INDEX_SET was an out-of-line helper
call costing roughly what computed-goto dispatch did. Stage 5 emits
the few-instruction fast paths inline and calls the helper only on
guard failure:

- **5a — buffer INDEX_SET**: inline guards (immediate-num index/value,
  heap target, `VAL_BUFFER` type, integral index, bounds) + the
  bounds-checked store, stack commit, and target decref. Any guard
  failure jumps to the existing helper call, which owns all other
  target types and the error paths.
- **5b — GET_NAME / SET name family EnvIC**: the IC entry address is
  baked per call site (the constant pool is final by JIT time); the
  inline path does the starting-env identity + binding-version guards,
  walk-depth 0/1 target resolution, and the slot load+incref (GET) or
  `env_store_slot`-equivalent swap with assign-counts bump (SET).
  Traced assigns (`g_trace_hist`), arena-pointer stores, and IC misses
  route to the helper, which also repopulates the IC. A new `%r15`
  frame-pointer cache (scanner flag `needs_frame_cache`) feeds the
  inline paths; it is pushed twice to preserve the body's
  %rsp ≡ 8 (mod 16) call-alignment invariant.
- **5c — `__loop_iterations__` write cache**: the per-iteration
  `env_set_local` in LOOP_STALL_CHECK (name hash + table walk +
  make_num/decref round-trip, every iteration of every `loop while`)
  now goes through a per-thread (env, binding_version, slot) cache and
  overwrites the immediate-num slot in place, with the same
  assign-counts bump. Semantics unchanged — mid-loop reads see the
  same values — so this also speeds the interpreter.

Numbers (5-run medians): bench_dmg_shape 239→218 ms (−9%),
bench_idxset 29.7→24.6 ms (−17%). Targeted probes isolate the inline
wins: a 2M-iteration module-scope `acc is acc + g` loop runs
191→56 ms (3.4×), a 2M-write unobserved buffer loop 215→77 ms (2.8×).
EIGS_JIT_STOPS stays at zero bailouts on both benchmarks.

Also fixes tests/test_leak_guard.sh, whose standalone ASan build was
missing trace.c and silently skipping since the trace tape landed.

### Performance — JIT coverage: SET name family (Stage 4x)

`SET_NAME`, `SET_NAME_LOCAL`, and `SET_FN_NAME_LOCAL` now compile into
thunks via out-of-line helpers on the GET_NAME ABI (chunk pointer +
name index; interpreter semantics verbatim — trace hook, EnvIC fast
path, resolve/create slow path; no stack effect, no error paths). With
Stage 4v/4w this closes the coverage chain: the fn-local index-write
benchmark compiles to a single thunk with zero bailouts, and
bench_dmg_shape's only remaining bailout is a one-time `DICT` literal.

Honest numbers: flat. Helper-call ABI costs roughly what computed-goto
dispatch did, so coverage alone doesn't move timings — it removes the
structural blocker. The next stage (recorded in ROADMAP.md) is
inlining the EnvIC fast paths into native templates with helper
fallback on IC miss; whole-loop thunks are the prerequisite this
stage delivers.

### Performance — JIT coverage: INDEX_SET + LOOP_STALL_CHECK (Stage 4v/4w)

Driven by the EIGS_JIT_STOPS bailout histogram on the new DMG-shaped
benchmark: INDEX_SET was the only bailout opcode, and LOOP_STALL_CHECK
surfaced next (every observed `while` loop carries one per iteration).
Both now compile into thunks via out-of-line helpers — INDEX_SET on
the INDEX_GET ABI (full opcode semantics in the helper, no bail path),
LOOP_STALL_CHECK on the ITER_NEXT shape (helper returns the exit flag,
emitter conditional-jumps to the exit target). No measurable benchmark
delta on its own: thunks now stop at the name-op family (SET_NAME /
SET_NAME_LOCAL and their inline caches), which is the next stage and
where the accumulated coverage should pay off. jit_smoke gains stubs.

### Performance — temporal history is now compile-gated

Profiling a DMG-shaped dispatch workload (new
`tests/bench_dmg_shape.eigs`, 500k dispatch-table steps) showed the
0.11.7 reversibility machinery running unconditionally: 17.8M
`trace_line` and 2.5M `trace_assign` calls — roughly a third of
runtime — whether or not the program ever asked a temporal question.

- **`g_trace_hist`**: per-assign history recording (prev-table, line
  stamps, tape `A` records) now gates on a compiler-set flag, enabled
  by `prev of`, any `at <expr>` qualifier, a `state_at` reference, or
  an open `EIGS_TRACE` tape. `OP_LINE` stores the current line as a
  plain global write instead of a call. Programs with no temporal
  queries also stop accumulating history memory entirely.
- Measured: dmg-shape 295 → 243 ms (−18%); for-loop 50k −32%;
  while 100k −23%; listcomp 20k −57%; observe 10k −44%.
- Post-fix profile for the 0.12.0 push: ~65% vm_run dispatch, then
  env churn (2.58M `env_free`/run ≈ one per call) and `make_num`
  (2.1M). Recorded in ROADMAP.md.

### Fixed
- **Exit-time segfault when a top-level `unobserved` block promoted
  module slots.** Module chunks carry promoted `local_count` slots
  without a `local_names` array (only fn/lambda chunks build one);
  `chunk_free`'s name loop dereferenced NULL. Latent since the loop
  was written — exposed the moment script chunks became freeable
  (0.11.8 chunk refcounting), and invisible to the suite because the
  crash lands *after* correct output and most checks ignore exit
  codes. New suite check [71] runs a promoting script and asserts
  rc=0.

### Added — temporal interrogatives complete the matrix

- **`where`/`why`/`how ... at <line>`** — the observer-derived
  interrogatives now answer historically. Each assignment's history
  entry stamps an observer snapshot (entropy, dH, last_entropy) taken
  with the same ensure-fresh semantics a live query uses, so
  `why is x at 42` returns exactly what `why is x` would have at that
  moment. Capture is compile-gated (`g_trace_obs_hist`): the compiler
  flips it when it sees such a query, so programs that never ask pay
  nothing and the lazy-entropy optimization is undisturbed. Snapshots
  live in a parallel array keyed off the history index (`obs_start`
  handles capture enabling mid-run via eval/REPL). Regression:
  test_temporal.eigs [70] grows to 23 checks, comparing historical
  answers against live values captured at the time.
- **`EIGS_REPLAY_STRICT=1`** — replay name mismatches become fatal
  (diagnostic + exit 3) instead of warn-and-use-anyway, for harnesses
  where tape/program drift should fail loudly. Default stays lenient.
  Regression: test_replay.sh grows to 6 checks (lenient + strict).

## [0.11.8] — 2026-06-10

A reversibility-hardening + memory-correctness release: `state_at`
gets its Phase 4 snapshot cache, container values replay from tape,
the entire suite runs leak-clean under AddressSanitizer (now enforced
in CI), and bytecode chunks are reference-counted — closing the last
deliberate leak and a REPL use-after-free.

### Added — chunk refcounting

Bytecode chunks now carry a refcount: one creator ref (the
`compile_ast` caller, or the parent chunk's `functions[]` slot for
nested chunks), one per live `VAL_FN` (taken in `OP_CLOSURE`, dropped
in `free_val`), and one per active call frame (so a function whose
last value ref dies mid-call cannot have its code freed under it; the
fn value was already popped and decref'd before frame push). JIT
return thunks write `chunk->jit_advance` *after* `jit_helper_return`
runs, so the popped frame's chunk ref is released in vm_run's post-
thunk sentinel handler rather than the helper. The JIT hotness
registry drops its bare pointer via `jit_unregister_chunk` when a
chunk dies.

Consequences: the script path, REPL, `eval`, `load_file`, and
`import` now free their chunks unconditionally (`import` previously
leaked its module chunk entirely); the REPL/`eval` fn-defining-chunk
retention workaround is gone; atomics gate on `g_vm_multithreaded`
like every other refcount.

### Fixed — memory: the suite now runs leak-clean under ASan

Chased the "intentional don't-free-at-exit baseline" and found it was
hiding real per-call leaks and one use-after-free. Every script the
suite runs — all 1279 checks, all 28 example smokes — now exits with
zero ASan leak reports, and CI's sanitizer job runs with
`detect_leaks=1` so any new leak fails the build.

- **Use-after-free: REPL functions died with their chunk.** The REPL
  freed each line's compiled chunk after execution, but fn values hold
  bare pointers into the chunk's nested function chunks — defining a
  function on one REPL line and calling it on a later line read freed
  memory (release builds survived by luck). Chunks that define
  functions are now intentionally retained (same policy as the script
  path's existing chunk TODO); function-less chunks are freed.
- **Stranded birth refs at every adopting store.** `env_set_local`,
  `list_append`, and `dict_set` all incref internally, so the
  ubiquitous `store(make_value(...))` idiom left every stored fresh
  value at refcount 2 with one owner — unfreeable by any teardown. New
  adopting helpers `env_set_local_owned` / `list_append_owned` /
  `dict_set_owned` consume the birth ref; 245 builtin registrations,
  67 list appends, and 49 dict stores converted. Recurring-leak
  call sites fixed along the way: `json_decode` (whole parse tree,
  per call), `json_path` (root tree, per call), `observe` (report
  string), `sort_by` (key results), `args`, `random_normal` (rows),
  `tensor` element-wise/unary/zeros builders, the `numerical_grad`
  family (probe values double-ref'd, loss results never released,
  zero placeholders overwritten without release), closure param
  temporaries (one strdup'd array per closure creation), per-env
  `assign_counts` (every env teardown), and the REPL's per-line AST
  and result values. `try_parse`/`eval` now free their ASTs.
- **Global env teardown at exit.** `env_free` is refcount-honest and
  no-ops while closures hold the env — at exit that leaked the whole
  global scope (191 builtins minimum) because top-level fns live in
  the env they capture. New `env_destroy_final` breaks the cycle
  reentrancy-safely; main tears down trace → env → arena in that
  order on both the script and REPL paths.
- **Replay no longer performs the live work it discards.** Builtins
  that did real I/O before their tape hook (`read_bytes`,
  `read_bytes_buf`, `read_text`, `random_normal`, `http_post`) ran
  that work under `EIGS_REPLAY` and leaked the abandoned live value —
  `http_post` even issued the real network request. New
  `TRACE_NONDET_TAKE`/`TRACE_NONDET_RECORD` pair consumes the call's
  N record up front (exactly one record per call, ordering contract
  intact) and skips the live path entirely.

### Added
- **Line-floor index for backward temporal queries** (the deferred
  Phase 4 snapshot cache). Each name's assignment history now carries
  a periodic index: the minimum line stamp per 64-entry segment.
  `state_at(line)` and the `at <line>` interrogative qualifier skip
  whole segments whose floor exceeds the query line — the loop-heavy
  worst case (deep histories stamped with the same few lines, i.e. a
  debugger scrubbing the timeline) drops from O(H) to O(H/64 + 64)
  per name. Measured: 200 `state_at` queries against 200 000-entry
  histories went from 58 ms to 1.1 ms (~50×). Overhead is one `int`
  per 64 history entries and an O(1) min-update per assign; if the
  index allocation ever fails the name falls back to the plain linear
  scan. Regression: `tests/test_temporal.eigs` ([70], 18 checks) —
  first suite coverage for `prev of` / `at` / `state_at`, including
  a 300-assign loop history that crosses several index segments.
- **Replay of container values.** `parse_value` in `src/trace.c` rewritten
  as a recursive-descent cursor parser; nondet returns that are lists,
  dicts, or buffers now round-trip through `EIGS_REPLAY` instead of
  falling through to the live source (closes the "containers return null"
  caveat from 0.11.7). Buffer serialization gains a leading `b` so
  `b[1,2,3]` disambiguates from a list `[1,2,3]`. Regression:
  `tests/test_replay.sh` — list (`read_bytes`), buffer (`read_bytes_buf`),
  dict (handcrafted `N` record), and nested list-of-dicts-and-buffer;
  each case mutates the underlying file between record and replay to
  prove the value comes from the tape.

### Documentation
- Documented the 0.11.7 reversibility surface: temporal interrogatives
  (`prev of`, `at`) in SYNTAX.md and GRAMMAR.md, `state_at` in
  BUILTINS.md, and a new docs/TRACE.md covering the `EIGS_TRACE` /
  `EIGS_REPLAY` tape format and replay semantics.
- Folded an orphaned `[Unreleased]` section (between 0.10.0 and 0.9.3.4)
  into the 0.10.0 entry it shipped with.

## [0.11.7] — 2026-06-09

A trace + time-travel release. The interpreter learns to remember its
own past — both at the language level (interrogatives that query prior
state) and at the runtime level (a recordable, replayable tape of every
nondeterministic input). The graphical debugger gains step-back.

### Added — Temporal interrogatives

- **`prev of x`** — value of `x` immediately before its most recent
  assign. Parsed with the `of` connector (vs. `is` for what/who/when),
  encoded as interrogative kind 6. Backed by a process-wide prev-table
  keyed by interned-name pointer (open-addressing, fibonacci-hashed),
  populated on every `OP_GSET`. Cost per assign: one cache line + a
  pointer compare. Works whether or not `EIGS_TRACE` is set — this is
  language surface, not debug-only.
- **`at <expr>` qualifier** — any interrogative can be temporally
  qualified: `what is x at 42`, `prev of x at L`, `when is x at L`,
  `who is x at L`. Walks per-name history (line-stamped, append-only)
  backward to the last assign with line ≤ L. The line operand is a
  full expression; `at` is a soft keyword that falls back to `IDENT`
  outside interrogative position. Lib/example collisions (`prev` as
  a variable in `lib/eigen.eigs`, `examples/invariant_decomposition.eigs`)
  renamed to `prior` to make the keyword unambiguous.

### Added — Execution trace tape

`EIGS_TRACE=<path>` opens a text tape and records three event kinds:

- `L <line>` — source-line events from `OP_LINE` (adjacent duplicates
  with no A/N in between are deduped — the compiler emits per-statement
  LINEs and bare repeats are noise).
- `A <name>=<value>` — name-keyed assignment deltas.
- `N <fn>=<value>` — nondeterministic builtin returns (random,
  monotonic_*, env_get, read_*, random_hex, http_post, …).

Full-fidelity nondet writer: per-record byte budget of 64 KiB, recursive
emission of lists/dicts/buffers, strings escape `\"`, `\`, `\n`, `\r`,
`\xNN`, truncation marker on overflow so partial records remain visually
parseable. Disabled cost is one predicted-not-taken load + branch at each
hook site.

### Added — HTTP nondet capture

The HTTP extension's request/response surface is nondeterministic from
the script's perspective. Wrapped returns in `ext_http.c` for:

- `http_post` (success + 7 error paths)
- `http_request_body`, `http_session_id`, `http_request_headers`
  (TLS-state-or-default returns)

Every call lands on the tape as an `N` record, making HTTP-driven
EigenScript runs reproducible.

### Added — Deterministic replay

`EIGS_REPLAY=<path>` opens a previously-recorded tape and serves the
`N` records to nondet builtins in order. Subsequent runs produce
byte-identical output: same random sequence, same monotonic_ns
timestamps, same HTTP responses. Implementation:

- Streaming reader skips `L` and `A` records, parses the next `N`
  value (num/null/bool/string today; lists/dicts return null so the
  builtin falls back to the live source — future work).
- Tape exhaustion gracefully switches off replay; remaining calls hit
  the real source.
- Name mismatches log a warning and use the recorded value anyway
  (lenient Phase 3.0 policy — strict ordering is the contract, names
  are for human-readable debug).
- `TRACE_NONDET_RET` centralized in `trace.h` so the replay short-circuit
  applies uniformly to every nondet builtin; three duplicate copies in
  `builtins.c`, `builtins_tensor.c`, `ext_http.c` removed.

### Added — `state_at(line)` builtin

Returns a dict of every tracked binding's value at or before `line`.
Walks the prev-table's per-name history with backward linear scan —
the existing history records `(line, value)` on every assign, so no
separate snapshot data structures were needed. Periodic snapshot
caching deferred until the linear scan is a profiled bottleneck.

### Added — Debugger step-back UI

`examples/debugger.eigs` gains F8/F11 history navigation while paused:

- The debug hook captures `(line, env-snapshot)` on every statement.
  Snapshots flatten the meta-circular env chain into a `{name: value}`
  dict (inner shadows outer; fn-shaped values skipped). FIFO-capped
  at 10 000 steps.
- F8 walks the view cursor backward; F11 forward; the cursor snaps
  back to live (-1) at the end or when execution resumes (F5/F9/F10).
- Inspector reads from the snapshot; source view highlights the
  historical line in cool blue (vs. live yellow); status bar switches
  to `History step K/N — line L`. Toolbar gains `Back F8` / `Fwd F11`.
- Trace machinery is not wired in here: it tracks host-VM globals,
  and the meta-circular interpreter has its own env dict. Snapshotting
  in the hook is the layer that actually owns the data.

### Suite

1257/1257 base, 15/15 HTTP, all three build variants (default, http+model,
gfx) green.

## [0.11.6] — 2026-06-09

### Fixed (HTTP server availability + protocol hygiene)

Surfaced by attacking the EigenScript HTTP runtime locally against the
landing site at `eigen-site/`. Code review and the existing test harness
both missed these — the underlying defects were architectural (single
accept loop) or in branches the test suite never exercised (HEAD, bad
versions, oversized headers).

- **Single-threaded accept → trivial slowloris DoS.** `http_serve_blocking`
  ran `handle_request` synchronously on the accept thread, so one client
  that opened a TCP connection and sent a partial header line wedged
  every subsequent request until the per-connection deadline expired.
  200 such connections from one host took the site offline. Accepts now
  hand each connection to a detached pthread; the request-state globals
  (`request_body`, `request_headers`, `session_id`, plus a new HEAD
  body-suppression flag) moved to `__thread` storage so workers don't
  trample each other. Concurrency is capped at 256 active connections;
  past that the listener sheds load with `503 Service Unavailable`
  instead of queueing. Regression: `tests/test_http_server.sh` HS13
  (16 slow conns served + GET still completes in <1.5 s).
- **HEAD requests returned 404.** Only GET routes were registered, so
  `HEAD /` fell through to the not-found path even when `GET /` existed.
  HEAD now reroutes to the GET handler and `send_response` skips the
  body via a TLS suppression flag, so callers get correct headers and
  Content-Length with an empty body. Regression: HS10.
- **HTTP version was unvalidated.** `sscanf` read the third token of the
  request line without checking it, so `GET / HTTP/junk` was served as
  200 OK. Now strictly requires `HTTP/<digit>`; everything else gets a
  400. Regression: HS11.
- **OPTIONS preflight returned 200 with empty body and no Allow header.**
  Any client probing methods got a content-free 200 instead of a proper
  preflight. Now answers 204 No Content with `Allow: GET, HEAD, OPTIONS`
  and mirrors CORS headers when `http_cors` is configured. Regression:
  HS07/HS07b.
- **Negative / oversized Content-Length hung the connection.** The old
  guard `free(reqbuf); close(fd)` silently dropped the request, so the
  client waited until its own timeout (or, with worse luck, until the
  30 s per-connection deadline). Now answers `400 Bad Request` with a
  reason string so misbehaving clients see a real error. Regression:
  HS08.
- **Oversized headers were silently truncated to 200 OK.** When the
  request-buffer ceiling (`max_body + 64 KiB`) was hit *before* finding
  `\r\n\r\n`, the read loop broke out and `sscanf` happily parsed the
  request line from whatever prefix had arrived — so a 17 MiB X-Big
  header value yielded a 200 instead of 431. Now answers `431 Request
  Header Fields Too Large` whenever the buffer caps with `header_end`
  still unset. Regression: HS12.

### Removed (struct hygiene)
- Removed `request_body`, `request_headers`, `session_id` from the
  `Server` struct in `ext_http_internal.h` (and their two zero-inits in
  `main.c`). These fields are now thread-local per the threading fix,
  so the struct slots were dead.

## [0.11.5] — 2026-06-09

### Fixed (memory safety)
- **Per-call leak from compensating incref on builtin returns.** The
  `CASE(CALL) VAL_BUILTIN`, `jit_helper_call`, and `OP_DISPATCH` paths
  unconditionally `val_incref`'d the result of every builtin call to keep
  borrowed pointers (e.g. `coalesce`/`append` returning `arg->items[k]`)
  alive across the subsequent `val_decref(arg)`. The same `+1` also fired
  for builtins that return a *fresh* allocation (`range`, `make_str`,
  `keys`, …), so every such call leaked one `Value` plus its contents.
  `for i in range of 1M` silently retained ~80 MB. Replaced with a
  direct-borrow scan that only incref's when `result` is one of `arg`'s
  top-level items; nested borrows like `get_at` keep their local incref.
  `OP_DISPATCH` additionally had `val_decref(arg)` *before* the incref,
  which was a UAF for direct borrows — reordered to match `CASE(CALL)`.
  Regression: `tests/test_leak_guard.sh` (ASan).
- **Use-after-free on consuming builtins via the direct-borrow scan.**
  The leak fix's borrow scan reads `arg->type` *after* the builtin call,
  but `free_val` is a consuming builtin that decrefs `arg` internally —
  on a refcount-1 argument that left the scan reading freed memory. The
  full-suite ASan/UBSan CI job (which a targeted leak guard couldn't have
  caught — the corruption is invisible without a sanitizer watching)
  surfaced it. Gated the scan and the trailing `val_decref(arg)` on
  `!consumes_arg` at all three call sites (`CASE(CALL)`, `jit_helper_call`,
  `OP_DISPATCH`).

### Added (infrastructure)
- **Cross-platform / cross-compiler CI matrix.** `.github/workflows/ci.yml`
  now runs `build-and-test` across ubuntu-latest+gcc, ubuntu-latest+clang,
  and macos-latest+clang (fail-fast off so one platform's failure doesn't
  hide the others), plus a dedicated `sanitizers` job that builds the
  whole runtime with `-fsanitize=address,undefined` and runs the full
  suite under it. `build.sh` honors `$CC` so the matrix can pick the
  compiler. New `make asan` target for local memory-bug hunting.
- **`tests/test_leak_guard.sh`** — ASan regression guard for the builtin
  ref-protocol leak. Builds a minimal ASan eigenscript, runs `range` /
  `make_str` / `keys` / `append` loops, fails if `make_list`/`make_str`/
  `make_dict` appear in any leak frame or if `append`'s borrowed return
  surfaces a UAF. Skips cleanly when ASan is unavailable. Wired into
  `run_all_tests.sh` (step `[69]`).

### Fixed (portability)
- **Non-x86 builds (notably macOS arm64).** `eigs_jit_get_layout` used
  inline `__asm__("mov %%fs:0, %0" ...)` to read the x86-64 thread
  pointer for TLS-relative JIT encoding. JIT codegen is already gated
  `#if defined(__x86_64__)` in `jit.c`, so the layout probe only matters
  there; on other arches the function body now collapses to a no-op
  rather than failing to assemble.
- **macOS test portability.** `test_file_io.eigs` RT1 stops reading
  `/etc/hostname` (Linux-only path) — it now stages a tmp file with
  `write_text` first, then reads it back. `test_coverage_gaps.eigs` CG12
  accepts `/private/tmp` as well as `/tmp` for the `chdir`+`getcwd`
  check, since macOS routes `/tmp` through a symlink.

### Documentation
- **README / ROADMAP refresh.** Updated stale binary size (`~328K` →
  `~420K`) and test count (`831/832` → `1257`) in README. Bumped
  ROADMAP's "Current version" from `0.11.0` to `0.11.4`; moved
  in-place numeric mutation, dict field inline caching, dispatch
  builtin re-entry elimination, and the DMG 0.5+ MHz target out of
  "Next" into "Completed"; reframed 0.12 around the copy-and-patch
  JIT + NaN-boxing prerequisites.

### Removed (code hygiene)
- **Dead statics in `src/compiler.c`.** `block_has_closure`, `emit_u16`,
  `begin_scope`, `end_scope`, and `root_compiler` were defined but
  never called, generating `-Wunused-function` warnings on every
  build. Removed.

### Security
- **Bounded parser recursion depth (stack-exhaustion guard).** The
  recursive-descent parser had no bound on expression nesting, so deeply
  nested source — e.g. `eval` of untrusted input like `((((…))))` — could
  exhaust the C stack and crash. Added a 256-level cap (shared by nested
  expressions and blocks); over-deep source now produces a parse error
  instead of a crash. (Block nesting was already capped at 64 by the
  lexer's indent limit; this closes the expression side.)
- **Constant-time secret comparison (`secure_equals` builtin).** Added
  `secure_equals of [a, b]`, which compares two strings without
  short-circuiting on the first differing byte, and switched `lib/auth.eigs`
  to use it for password and bearer-token checks so comparison timing can't
  leak how many leading bytes matched. Regression:
  `tests/test_security_hardening.eigs`.
- **Bounded JSON nesting depth (stack-exhaustion DoS fix).** The recursive
  JSON parser (`eigs_json_parse_value` → array/object) had no depth limit,
  so deeply nested input like `[[[[…]]]]` exhausted the C stack and crashed
  the process with SIGSEGV. Reachable by any program that `json_decode`s
  untrusted input — notably an HTTP server decoding a request body — making
  it a remote denial of service. Added a 200-level nesting cap; input past
  it is refused and parsing terminates cleanly instead of crashing. Normal
  documents are unaffected. Regression: `tests/test_json_depth.eigs`.

### Added
- **`docs/LANGUAGE_CONTRACT.md`** — the language's semantic promises stated
  explicitly (equality, ordering, coercion, errors, numbers, truthiness,
  scope, evaluation, mutability/aliasing, argument unpacking, the full
  operator-precedence table, and indexing), each with an Enforced/Planned
  status and a link to the test that locks it. A living spec to extend
  before adding features.
- **`tests/test_call_semantics.eigs`** — locks two previously-undocumented
  promises: argument unpacking (≥2 params spread a list; a lone param binds
  the whole argument) and reference aliasing (assignment shares containers,
  does not copy).
- **`tests/test_stem_accuracy.eigs`** — a 123-check known-answer audit of
  the STEM libraries (physics, chemistry, biology, engineering, geometry,
  linalg, calculus, probability, stats, numerics, optimize) against
  textbook values. Every check passes: e.g. `gravitational_force` matches
  the 2019 CODATA G, `normal_pdf(0,0,1)` matches 1/√(2π) to 16 digits,
  `rk4` lands on e, Simpson/trapezoidal/midpoint integration and Newton/
  secant/bisection root-finding all hit their analytic answers.
- **`variance_sample` / `std_dev_sample`** in `lib/stats.eigs` — sample
  variance/standard deviation with Bessel's correction (÷N−1). The
  existing `variance`/`std_dev` remain **population** statistics (÷N); the
  difference is now documented in the source and both forms are tested.

### Changed (behavior change)
- **`==` / `!=` are now structural for collections.** Lists and dicts
  previously compared by reference identity, so `[1,2] == [1,2]` was
  `false`. They now compare by structure (lists element-wise, dicts by
  key/value order-independently, buffers/text-builders by contents);
  numbers/strings/null by value; functions and builtins still by identity;
  mixed types are never equal (no coercion). This also makes `match` work
  on list/dict patterns. See `tests/test_equality.eigs`.
- **Numbers print round-trippably.** `value_to_string` used `%.6g`, which
  truncated every non-integer to 6 significant figures (and any integer
  >= 1e15 to lossy scientific form) — `1/3` printed `0.333333`,
  `0.1 + 0.2` printed `0.3`. It now emits the shortest representation that
  parses back to the same double (15–17 significant digits as needed), so
  `0.1 + 0.2` prints `0.30000000000000004` and `str`/`num` round-trip.
  Exact integers up to 2^53 still print without a decimal point. See
  `tests/test_number_format.eigs`.

### Changed (behavior change), continued
- **Mixed-type ordering now raises instead of silently returning false.**
  `<`, `>`, `<=`, `>=` previously returned `false` when the operands were
  different types (`"3" < 4` was `false`), masking type confusion. They
  now require both operands to be the same comparable type (number/number
  or string/string) and raise a runtime error otherwise (catchable with
  `try`/`catch`). Equality (`==`/`!=`) is unchanged: it never coerces and
  cross-type compares are simply not-equal, never an error.
- **`+` no longer coerces across types.** It adds two numbers or
  concatenates two strings; a mixed operand (`"n=" + 42`, `7 + "x"`) now
  raises instead of silently stringifying (`"3" + 4` used to be `"34"`).
  Use an f-string — `f"n={count}"` — or `str of` to mix types in text.
  (The old coercion path also truncated numbers via `%.14g`; that's moot
  now.) `of` precedence (`len of xs - 1` parses as `(len of xs) - 1`) is
  documented in docs/SYNTAX.md, not changed — the two natural readings
  conflict, and the current rule matches the common idiom.
- **Builtin argument errors now raise instead of warning and returning
  `null`.** `EigenStore` builtins (`store_open`/`put`/`get`/`delete`/
  `query`/`count`/`update`/`collections`/`drop`/`close`), `json_decode`,
  and `load_file` previously printed an `Error:`/`Type error:` line to
  stderr and returned `null` on bad input, so a misuse silently produced
  `null` and the program continued. They now route through the same
  `runtime_error` channel as the rest of the VM — caught by an enclosing
  `try`, otherwise fatal. Non-error outcomes are unchanged: a `store_get`
  miss still returns `null`, a `store_delete` of a missing key still
  returns `0`. (`runtime_error` is now declared in `eigenscript.h` and
  strips a trailing newline so caught messages are clean.) Remaining
  lenient spots, left for a follow-up: a file-open failure in the stream
  builtins, and the optional model extension.

### Fixed (behavior change)
- **Uncaught runtime errors are now fatal and set a non-zero exit code.**
  Previously an uncaught error (undefined variable, index out of range,
  calling a non-function, operator type mismatch, call-stack overflow)
  printed a message, substituted `null`, and execution *continued* — and
  the process still exited `0`. Scripts could fail silently and report
  success, and a stack overflow produced a cascade of follow-on errors
  rather than one. `vm_run` now unwinds to the nearest enclosing `try`
  (across re-entrant calls), or halts the program if there is none, and
  `main` returns `1` when an uncaught error occurred. `try`/`catch`
  behavior is unchanged; caught errors still let the program continue and
  exit `0`. Migration: wrap recoverable operations in `try`/`catch`.
  Note: builtins on the separate "soft" channel (e.g. `store_*` and
  `json_decode`, which print `Error:`/`Type error:` without raising) still
  return `null` and continue — unifying those into the strict model is a
  follow-up.

## [0.11.4] — 2026-05-23

### Performance
- **Intern dict-stored keys + pointer-equality short-circuit in dict
  inline cache**: dict keys were previously `xstrdup`'d at insert, while
  cache callers pass `chunk->const_interns[idx]` (interned strings) —
  pointer equality never matched, so every dict cache hit paid for a
  `strcmp`. Callgrind on the 0.11.3 PGO binary showed `__strcmp_sse2` at
  **4.06%** of retired instructions, dominated by `dict_get_cached` /
  `dict_set_cached` / `dict_set_cached_immediate`. Switched dict-key
  storage to `env_intern_name` (single insert site at
  `eigenscript.c:621`) and added `stored == key || strcmp(...)` to all
  three cache helpers. Hot DMG field accesses now short-circuit on
  pointer equality. DMG `cpu_instrs` (n=10, PGO, `--cycles 200000`)
  went from **1.042 MHz** to **1.094 MHz** mean (+5.0%).

### Build
- Added `make pgo` target: builds an instrumented binary, runs DMG
  cpu_instrs as the default training workload, then rebuilds with
  `-fprofile-use`. ~+8–9% net on the trained workload. `PGO_RUN` and
  `PGO_DIR` overridable for different training workloads.
- Fixed `build.sh` drift: missing `jit.c` in `SOURCES` (broke since the
  VM-layer split) and missing `EIGENSCRIPT_EXT_*` macros in the
  full-build branch.

## [0.11.3] — 2026-05-23

### Performance
- **Gate refcount atomics on `g_vm_multithreaded` flag**: on x86 every
  `__atomic_*_fetch` for refcount work emits a LOCK-prefixed RMW (~20
  cycles each), regardless of memory order. Added a runtime flag,
  default 0, flipped to 1 by `builtin_spawn` before `pthread_create`.
  All `val_incref/decref`, `slot_incref/decref`, and `env_refcount`
  inc/dec/load sites branch on the flag with `__builtin_expect(0)`
  and use plain `++/--` in the single-threaded case. DMG `cpu_instrs`
  (n=10, `--cycles 200000`) went from **0.767 MHz** (0.11.2 baseline)
  to **0.950 MHz** mean (+24%), clearing the Phase B Gate (0.85 MHz)
  with 12% margin.

### Diagnostics
- Per-chunk `jit_stop_op` field + extended `EIGS_JIT_HOT=1` table
  (adv/len/nat%/stop columns + aggregate native-byte share). Surfaces
  the static native-bytecode coverage of JIT-compiled chunks; revealed
  that helper-call prefix extension was hitting diminishing returns
  (~6% native-byte share across all hot chunks).

## [0.11.2] — 2026-05-22

### Bug Fixes
- **`break` in `while` loop corrupted stack**: AST_LOOP patched break
  jumps to land *after* its trailing OP_NULL, so the break path skipped
  the loop's result push while the compile-time tracker (and AST_BREAK's
  +1 phantom) assumed it was there. A statement following the loop then
  popped a stale heap pointer and segfaulted. Patch break jumps before
  OP_NULL so all exit paths agree.
- **`break` in `while` loop freed the global env**: AST_BREAK
  unconditionally emitted OP_LOOP_ENV_END, but only AST_FOR allocates a
  per-iteration env. Breaking out of a `while` therefore released the
  surrounding (often global) env. Track `has_fresh_env` per loop and emit
  OP_LOOP_ENV_END only when set.
- **`local[const]` indexing silently masked errors**: OP_LOCAL_IDX_GET
  (the fused fast path for `arr[i]` on a local slot) returned null on
  out-of-range or wrong-type targets instead of raising runtime_error.
  This made try/catch around errors-inside-functions appear broken
  (error never propagated; function silently returned null). Bring its
  error semantics in line with unfused INDEX_GET.
- **`local[const].field` silently masked errors**: same class of bug in
  OP_LOCAL_IDX_DOT_GET / OP_LOCAL_IDX_DOT_SET. Out-of-range list index
  silently returned null / no-op; non-list non-null targets silently
  failed. Now error like unfused INDEX_GET/INDEX_SET + DOT_GET/SET.
- **64K buffer index truncation**: `idx < (uint16_t)count` truncated
  count to 16 bits — a 65536-byte buffer (e.g. a Game Boy 64K address
  space) reported every index as out-of-range. Compare as int.

### Cleanups
- Drop redundant `slot < (uint16_t)e->count` casts across 7 slot-bounds
  checks in GET_LOCAL / SET_LOCAL / LOCAL_DOT_GET/SET / LOCAL_IDX_GET /
  LOCAL_IDX_DOT_GET/SET. Compare `(int)slot < e->count` directly.

### Test Suite
- Full suite now reaches **1030/1030 PASS, 0 FAIL** (previously halted
  at `[29/31] Break & Continue` on the segfault above, reporting 141
  PASS).

## [0.11.1] — 2026-05-21

### Performance (DMG benchmark: 0.318 → 0.384 MHz, +21%)
- **In-place numeric mutation**: arithmetic ops reuse refcount-1 Values
  instead of allocating via make_num.
- **Dict field inline cache**: 128-entry direct-mapped cache for
  DOT_GET/DOT_SET (99.99% hit rate on DMG workload).
- **Superinstructions**: LOCAL_DOT_GET/SET, LOCAL_IDX_GET,
  LOCAL_IDX_DOT_GET/SET fuse 2-4 dispatches into one.
- **Stack-top arithmetic**: ARITH_FAST macro operates directly on
  stack[] without push/pop for num+num fast path.
- **JUMP_IF_FALSE/TRUE**: inlined numeric check bypasses is_truthy().
- **POP**: inlined val_decref avoids function call.

### Bug Fixes (Audit)
- **Break in for-loops**: emit LOOP_ENV_END before break jump to
  prevent env leak and stack corruption.
- **Observer `who is x`**: returns binding name ("x") instead of type
  name ("number"). New OP_INTERROGATE_NAMED opcode.
- **Observer `when is x`**: returns assignment count via per-slot
  assign_counts[] in Env. Tracks increments across env_set.
- **Compound assignment `a[f()] += x`**: index expression now evaluated
  exactly once via new OP_DUP2 opcode + compiler bytecode lowering.
- **Bitwise precedence**: comparison RHS now parses bitwise operators
  (`1 == 1 | 0` works).
- **Dict non-string keys**: runtime error instead of silent collapse
  to "?" key.
- **Postfix after grouping**: `(expr).field` and `(expr)[idx]` both
  parse correctly.
- **Dedent validation**: mismatched indentation levels now produce
  syntax errors.
- **Superinstruction error semantics**: LOCAL_DOT_GET/SET emit proper
  runtime_error for non-dict targets (was silently returning null).

### New Opcodes
- `OP_DUP2` — duplicate top two stack values
- `OP_INTERROGATE_NAMED` — who/when with binding name operand
- `OP_LOCAL_DOT_GET`, `OP_LOCAL_DOT_SET` — fused local.field access
- `OP_LOCAL_IDX_GET` — fused local[const] access
- `OP_LOCAL_IDX_DOT_GET`, `OP_LOCAL_IDX_DOT_SET` — fused local[n].field

## [0.11.0] — 2026-05-21

### Bytecode VM Completeness
- **Zero VM bugs remaining.** Fixed all 14 bytecode VM test failures
  from the 0.10.0 release. The VM is now fully compatible with the
  tree-walker's behavior across all 92 test files.

### Bug Fixes
- **Try/catch handler stack**: nested try/catch with rethrow now works
  correctly (max 8 nested per frame).
- **Type error reporting**: runtime_error for SUB, MUL, DIV, MOD, NEG
  on wrong types; DOT_GET/DOT_SET on non-dict; INDEX_GET/INDEX_SET
  for OOB and non-indexable; ITER_SETUP for non-iterable.
- **Error message compatibility**: "out of bounds" → "out of range";
  WHO interrogative returns "number"/"string"/"function" (not short names).
- **Division by zero**: warning to stderr instead of runtime_error
  (matches tree-walker behavior).
- **String concatenation**: string + non-string uses value_to_string
  instead of returning null.
- **Builtin result refcount**: sort/append returning their input no
  longer causes double-free.
- **Listcomp with filter**: save/restore stack depth at filter branch
  point (was crashing).
- **Break/continue outside loop**: emit NULL instead of phantom stack
  adjust (was corrupting closures containing break).
- **Observer obs_age**: increment in update_observer (was missing after
  eval.c → eigenscript.c migration).
- **1-element list args**: `f of [x]` passes `[x]` as a list, not `x`
  as a scalar (fixes softmax, mat_det, and similar builtins).
- **0-param functions**: call_eigs_fn skips param binding when
  param_count == 0 (was accessing NULL params).

## [0.10.0] — 2026-05-21

### Architecture — Bytecode VM
- **Replaced AST tree-walker with bytecode VM.** All code now compiles to
  bytecode and runs through a stack-based VM with computed-goto dispatch.
  `eval.c` (1387 lines) deleted, replaced by `compiler.c` + `vm.c` + `chunk.c`
  (~2400 lines). Net +1250 lines for the entire VM.
- **60+ opcodes** covering all 31 AST node types: constants, arithmetic,
  comparison, bitwise, variables (local slots + name-based), control flow
  (jumps, loops, iteration), functions (closure, call, return), data
  structures (list, dict, index, dot), error handling (try/catch), observer
  system (interrogate, predicate, stall detection), and modules (import).
- **Non-recursive function calls.** `OP_CALL` pushes a new frame and
  continues the dispatch loop. No C stack recursion — recursion depth
  limited by `VM_FRAMES_MAX` (4096) instead of C stack size.
- **Stack-depth tracking** in the compiler validates branch/loop balance.
- **GET_LOCAL/SET_LOCAL** optimization for function parameters: direct
  env slot access bypasses hash table lookup.
- **Observer stall detection** (`OP_LOOP_STALL_CHECK`): while-loops exit
  after 100 iterations of `|dH| < threshold`. Sets `__loop_exit__` and
  `__loop_iterations__` env variables.

### Language
- **Compound assignment operators**: `+=`, `-=`, `*=`, `/=`, `%=`, `&=`,
  `|=`, `^=`, `<<=`, `>>=`. Desugared in the parser to existing AST nodes.
  Works on variables, dot-access, and index-access.
- **Buffer iteration**: `for x in buffer:` and `[expr for x in buffer]` now
  work. `what`/`who` interrogation handles buffers. VAL_BUFFER is now a
  first-class iterable type.

### Performance
- **For-loop env reuse**: Reuse a single `Env` per for-loop and list
  comprehension instead of allocating/freeing per iteration. Falls back to
  fresh allocation when closures capture the loop scope.
- **Lazy observer entropy**: Assignments mark values dirty; `compute_entropy`
  deferred until observer state is actually read. In-place NUM fast path
  eagerly computes entropy (O(1) for numbers).
- **Thread-local observer state**: `g_last_observer` replaces the
  `__observer__` env variable, eliminating hash lookup and atomic refcount
  per assignment and function call.
- **String concat fast path**: `make_str_owned` avoids double-copy;
  STR+STR concat skips `value_to_string`.
- **Keyword dispatch**: `keyword_type` uses `switch(word[0])` instead of
  37 sequential `strcmp` calls.
- **Environment hash index**: FNV-1a hash table for O(1) variable lookup in
  `env_get`/`env_set`/`env_set_local`, replacing linear scan.
- **Dict hash index**: Dicts now use the same FNV-1a hash table for O(1) key
  lookup in `dict_get`/`dict_set`/`dict_remove`, replacing O(n) linear scan.
- **Loop condition fast path**: `eval_num_fast` extended with comparison
  operators (`<`, `>`, `<=`, `>=`, `==`, `!=`). Loop conditions like
  `while x < limit:` now evaluate with zero allocation.
- **Relaxed atomic refcounting**: `val_incref` uses `RELAXED` ordering,
  `val_decref` uses `ACQ_REL` (was `SEQ_CST`). Eliminates unnecessary full
  memory barriers on every refcount operation.
- **Allocation origin fix**: `list_append` and `env_set_local` now use the
  owning structure's arena flag (not `g_arena.active`) to decide allocation
  strategy, eliminating the `is_arena_ptr()` linear scan on every
  `free_value`.
- **Memory leak fixes**: Safe `val_decref` on fresh Values from loop
  conditions, list comprehension filters, and match patterns. Closure
  environments are freed when all referencing closures are destroyed (atomic
  `env_refcount`). Thread `call_env` is freed after thread body completes.
  Arena overflow allocations are tracked and freed on `arena_reset`.
  `arena_destroy` frees all arena blocks at program exit.

### Builtins
- `list_truncate of [list, new_len]` — in-place O(1) list shrink.
- `list_remove_at of [list, index]` — in-place element removal with memmove.
- `sort_by of [list, key_fn]` — C-backed O(n log n) qsort with key function
  (replaces O(n²) pure-EigenScript insertion sort in lib/sort.eigs).
- `sign_extend of [val, bits]` — sign-extend a value from a given bit width
- `scan_ints of text` / `scan_ints of [text, comment_marker]` — C-backed scan
  of whitespace-delimited signed integer tokens, optionally skipping comment
  lines
- `scan_int_tokens of text` / `scan_int_tokens of [text, comment_marker]` —
  C-backed token spans with signed-integer classification and value metadata
- `text_builder_new`, `text_builder_append`, `text_builder_append_line`,
  `text_builder_extend`, `text_builder_part_count`, `text_builder_clear`,
  and `text_builder_to_string` — native growable text builder builtins used by
  `lib/text_builder.eigs`
- `sort of list` — in-place qsort on numeric lists
- `read_bytes_buf of path` — read binary file as VAL_BUFFER (zero per-element alloc)
- `gfx_fb of [buf, w, h, x, y, scale]` — blit a buffer as a scaled texture
- `ppu_render_frame of [mem_buf, fb_buf]` — full Game Boy PPU rendering in C

### Standard Library
- `lib/int_vector.eigs` wraps root buffers as fixed-size integer vectors for
  solver-style dense integer state, with direct indexing and copy helpers.

### Hardening
- Finite-number invariant: numeric construction, scalar arithmetic, tensor
  arithmetic, math builtins, and numeric fast paths now prevent `NaN`/`Inf`
  from entering EigenScript values. `NaN` collapses to `0`; overflow and
  infinity saturate at `+/-1e308`; domain-limited inverse trig clamps inputs.
- Shift-amount bounds checks (`<<`, `>>`) — out-of-range yields 0, not UB
- Null guards on dot-assign, index-assign, and list comprehension targets
- JSON control-character escaping for bytes < 0x20
- F-string recursion depth limit (max 64 levels)
- Parser bounds checks for lambda lookahead
- HTTP Content-Length search scoped to headers only
- Store handle release before free (use-after-free fix)

## [0.9.3.4] — 2026-04-25

### UI Toolkit

- **Widget registry**: replace 74 hardcoded type dispatches with registry
  pattern. Adding a new widget type now requires one registration block
  instead of editing 6+ functions.
- **Layout position caching**: cache absolute positions (`_ax`/`_ay`) during
  layout pass, eliminating 53 per-frame tree walks in event dispatch.
- **Frame-rate independent timers**: cursor blink and tooltip delay now use
  millisecond timestamps instead of frame counters.
- **Keyboard accessibility**: 10 widget types (grid, chart, bar_chart,
  color_picker, canvas, waveform_view, piano_kb, editable_label, code_view,
  gauge) are now keyboard-accessible via Tab + arrow/Enter/Space.
- **File decomposition**: split 4522-line `ui.eigs` into 14 focused files
  grouped by widget category.
- **UI unit tests**: 81 new assertions covering constructors, registry,
  layout, hit-testing, focus cycling, scroll clamping, and keyboard nav.

### Bug Fixes

- **SDL2 dlsym crash**: validate all `dlsym` results — missing symbols now
  fail with a diagnostic instead of segfaulting via NULL function pointer.
- **SDL2 audio null-check**: `audio_open` now checks for audio symbol
  availability before calling.
- **`gfx_open` window leak**: destroy window on renderer creation failure.
- **`gfx_close` resource leak**: close audio device and `dlclose` SDL2
  library handle on shutdown.
- **Focus ring overwrite**: focus ring no longer fills over widget content
  with `panel_bg`; draws four edge rects instead.
- **Scroll wheel targeting**: wheel events now scroll only the scrollable
  widget under the cursor, not all scrollable containers.
- **`gfx_delay` CPU burn**: increased from 1ms to 8ms for software-renderer
  fallback when vsync is unavailable.

## [0.9.3.3] — 2026-04-25

### Security
- **`screen_render` overflow**: validate screen dimensions (max 10000x10000),
  use `size_t` for buffer size and `xcalloc_array` for allocation.
- **`builtin_join` overflow**: use `size_t` for length accumulation and
  `xmalloc`/`xmalloc_array` for allocations instead of raw `malloc`.
- **Test runner injection**: pass values to Python via `sys.argv` instead of
  shell-interpolated string in `check_range`.

### Hardening
- Eliminate all `sprintf` from the codebase — replaced with bounds-checked
  `snprintf` in `hash.c` (`bytes_to_hex`) and `builtins.c` (`random_hex`).
- Eliminate all `strcpy` — replaced with `memcpy` of known-length constants
  in `lint.c` and `main.c`.
- Zero unsafe string functions (`sprintf`, `strcpy`, `strcat`, `gets`) remain.

## [0.9.3.2] — 2026-04-25

### Security
- **Lexer indent_stack overflow**: bounds-check indent depth (max 64 levels)
  before pushing to stack-allocated array.
- **Parser list/dict literal overflow**: bounds-check element count (max 1024)
  before writing to heap-allocated array.
- **`read_file_util` ftell guard**: reject negative ftell return before
  allocating and reading — prevents heap overflow on unseekable files.
- **`compute_entropy` depth guard**: cap recursion at 64 levels to prevent
  stack overflow on deeply nested list/dict values.
- **`value_to_string` depth guard**: same cap, returns `[...]` at depth 64.
- **CORS header injection**: strip `\r` and `\n` from CORS origin to prevent
  HTTP response header injection.
- **Static file TOCTOU**: serve the realpath-resolved canonical path instead
  of the original request path, closing the symlink-swap window.
- **HTTP route handler leak**: free TokenList after each request to prevent
  per-request memory leak under sustained traffic.
- **Model JSON array overread**: check for `]` before each element read in
  `json_parse_1d_array` to avoid reading past short arrays.
- **`save_model_weights` loop bounds**: use `size_t` for `vs * dm` loop bounds
  to prevent int overflow.

### Hardening
- **`env_set_local`**: emit diagnostic when scope exceeds MAX_VARS (512)
  instead of silently dropping bindings.

## [0.9.3.1] — 2026-04-24

### Security
- **Handle table**: Store, Thread, and Channel handles now use a validated
  handle table instead of storing raw C pointers as doubles. Forged or stale
  handle IDs return null instead of dereferencing arbitrary memory.
- **copy_into**: reject negative offset (was heap corruption via OOB write).
- **tensor_to_flat**: prevent integer overflow on large tensor dimensions via
  `safe_size_mul` and 10M element cap.
- **ext_db**: fix JSON injection in `db_connect` error path and
  `db_query_json` column names — replaced manual string interpolation with
  `eigs_json_escape_string`.
- **ext_http**: generate session IDs from `/dev/urandom` instead of
  predictable `time()+counter`; use stack-local buffer instead of static.
- **ext_http**: route code handlers now execute in an isolated child
  environment so side-effects don't leak across requests.

### Hardening
- Makefile: enable `_FORTIFY_SOURCE=2`, PIE, and full RELRO.

### Docs
- ARCHITECTURE.md: fix stale function names (`eval_stmt`→`eval_node`,
  `EigenValue`→`Value`, lexer location `eigenscript.c`→`lexer.c`).

## [0.9.3] — 2026-04-22

### New Libraries
- **`lib/geometry.eigs`**: Computational geometry — 60+ functions for 2D/3D
  points, vectors, line/segment intersection, triangles (area, centroid,
  circumcenter, incenter, barycentric coords), polygons (shoelace area,
  point-in-polygon ray casting, convexity), convex hull (Andrew's monotone
  chain), circles (from 3 points, intersection), 2D transforms (translate,
  rotate, scale, reflect), Hausdorff distance, solid geometry. 124 tests.
- **`lib/lab.eigs`**: Experiment and data collection framework composing
  EigenStore, observer semantics, stats, and experiment libraries. Real-time
  measurement stability detection, outlier flagging, tagged groups, CSV
  export, persistence via EigenStore.

### New Builtins
- **`set_observer_thresholds of [dh_zero, dh_small, h_low]`**: Tune observer
  classification thresholds for advanced use (slow convergence studies).
  Prints warning on change. Defaults: 0.001, 0.01, 0.1.
- **`get_observer_thresholds of null`**: Read current thresholds.

### Examples
- **15 STEM simulations** in `examples/stem/`: double pendulum chaos,
  radioactive decay chains, RC circuits, projectile drag, heat diffusion,
  Lotka-Volterra ecology, chemical kinetics, orbital mechanics, spring
  resonance, diffraction, genetic drift, eigenvalue vibration, acid-base
  titration, climate modeling, signal analysis.

### Hardening
- Documented Euler invariant in range builtin, suppressed cppcheck false flag
- Observer predicates and `report` now use tunable threshold variables
  instead of hardcoded constants (same defaults, no behavior change)

## [0.9.2] — 2026-04-22

### STEM Standard Library (12 modules, 500+ functions)
- **`lib/physics.eigs`**: 14 CODATA constants, 80+ functions — kinematics,
  projectile motion, forces, energy, waves, thermodynamics, electromagnetism,
  optics, special relativity, nuclear/quantum, fluid mechanics
- **`lib/chemistry.eigs`**: Periodic table (36 elements), molecular weight
  parser, stoichiometry, gas laws, acids/bases, thermochemistry, solutions
- **`lib/biology.eigs`**: Population dynamics, genetics (Hardy-Weinberg,
  Punnett), molecular biology (DNA complement, transcription, full 64-codon
  translation), enzyme kinetics, ecology (Shannon/Simpson diversity)
- **`lib/engineering.eigs`**: Unit conversions, signal processing (DFT/IDFT,
  convolution, spectrum), control systems (PID), structural (beam deflection,
  Euler buckling), electrical (impedance, resonance, dividers)
- **`lib/earth_science.eigs`**: Atmospheric science, seismology (Richter),
  oceanography, astronomy (Kepler, Schwarzschild, stellar luminosity, Hubble),
  climate science (CO2 radiative forcing)
- **`lib/linalg.eigs`**: Matrix operations, vector algebra, Gaussian
  elimination with pivoting, matrix inverse, least squares, 2x2 eigenvalues
- **`lib/calculus.eigs`**: Numerical differentiation (central difference,
  gradient), integration (trapezoidal, Simpson's, Monte Carlo), root finding
  (bisection, Newton-Raphson, secant), ODEs (Euler, RK4), Taylor series,
  interpolation
- **`lib/probability.eigs`**: Combinatorics, distributions (binomial, Poisson,
  normal, exponential, uniform — PMF/PDF/CDF), Bayesian inference, chi-squared

### Observer-Aware Libraries (unique to EigenScript)
- **`lib/optimize.eigs`**: Gradient descent with observer-adaptive learning
  rate, multi-variable optimization, simulated annealing, golden section,
  genetic algorithm — all use `report of loss` for convergence detection
- **`lib/simulation.eigs`**: Equilibrium detector, stability analyzer,
  spring-mass-damper, Lotka-Volterra, 1D heat equation — observer detects
  equilibrium, oscillation, and convergence
- **`lib/numerics.eigs`**: Jacobi/Gauss-Seidel iterative solvers, power
  iteration, fixed-point iteration — observer detects residual convergence
- **`lib/experiment.eigs`**: Measurement stability tracking, entropy spike
  outlier detection, convergence rate estimation, regime detection

### SDL2 Audio Extension
- 13 audio builtins: `audio_open/close/pause/play/queue_size/clear`,
  `audio_sine/saw/square/noise` (C synthesis), `audio_mix/gain/envelope`
- **`lib/audio.eigs`**: `play_note`, `note_freq`, `play_chord`, drum sounds

### Code Formatter & Linter
- **`eigenscript --fmt`**: Line-based formatter — indentation, spacing,
  trailing whitespace, blank lines, comment formatting. `--write` for in-place
- **`eigenscript --lint`**: AST-walking linter — unused variables, unreachable
  code, builtin shadowing, duplicate dict keys, empty blocks, unused params

### Hardening
- **Valgrind leak fix**: TokenList and AST now freed on exit (2MB → 1.8KB)
- **free_ast** made public for proper cleanup
- **shellcheck**: All warnings fixed in test runner
- **Linter dogfooding**: stdlib cleaned — `while` → `loop while` in audio,
  builtin shadowing fixed in validate/store, unused params prefixed with `_`

### Tidepool Game (near-parity with C version)
- Creature spec system (14-socket body plans, 5 palettes, visual traits)
- Multi-segment body rendering (wobble, patterns, appendages, eyes, mouths)
- Zone-based combat (front/side/rear power), poison clouds, electric bolts, jets
- Epic cells (leviathans) with suction, part drops, NPC combat
- Mating system + evolution, creature editor with UI toolkit
- Camera zoom by tier, caustic lights, particles, high score persistence

### Testing
- **~490 new STEM tests** verified against known scientific values
- 831+ total tests in core suite
- `cppcheck`, `valgrind`, `shellcheck` integrated into workflow

## [0.9.1] — 2026-04-21

### New Builtins
- **`sha256`** / **`md5`**: hash string to hex (SHA-256 FIPS 180-4, MD5 RFC 1321)
- **`sha256_file`** / **`md5_file`**: hash file contents
- **`hmac_sha256`**: HMAC-SHA256 (RFC 2104) for message authentication
- All zero-dependency — algorithms implemented directly in C

### Language Server Protocol
- **`eigenlsp`**: standalone LSP server (200K binary) for editor integration
- Diagnostics (parse errors), completion (keywords, 60+ builtins, symbols),
  hover (docs, signatures), go-to-definition, find-references
- Column tracking added to Token and ASTNode for precise source locations
- VS Code extension with TextMate syntax highlighting grammar

### Runtime
- Column numbers on all tokens and AST nodes (lexer + parser)

### Testing
- 831 tests (up from 817 in 0.9.0)
- Hash builtins verified against NIST/RFC test vectors

## [0.9.0] — 2026-04-21

### Language
- **Index-assignment syntax**: `list[i] is value`, `dict[key] is value` —
  new `AST_INDEX_ASSIGN` node. Supports chained access: `items[0].x is 10`,
  `grid[r][c] is val`. 15 tests.
- **Real concurrency**: 12 global variables converted to `__thread` thread-local
  storage. Each OS thread gets its own eval state, error handling, and arena.
  Atomic `val_incref`/`val_decref` for thread-safe reference counting.

### New Builtins
- **`spawn(fn)`**: create a pthread running an EigenScript function, returns handle
- **`thread_join(handle)`**: block until thread completes, returns result
- **`channel(null)`**: bounded mutex/condvar channel (64 slots)
- **`send([ch, val])`** / **`recv(ch)`**: channel message passing (blocks when full/empty)
- **`close_channel(ch)`** / **`channel_closed(ch)`**: channel lifecycle
- **`gfx_rrect`**: filled rounded rectangle with optional alpha
- **`gfx_clip`**: render clip rectangle (wraps SDL_RenderSetClipRect)
- **EigenStore database**: `store_open`, `store_close`, `store_put`, `store_get`,
  `store_delete`, `store_query`, `store_count`, `store_update`, `store_collections`,
  `store_drop` — zero-dependency page-based embedded database

### SDL2 Graphics
- Mouse wheel events (`SDL_MouseWheelEvent`)
- Modifier keys on key events (`shift`, `ctrl`, `alt`)
- Full a-z + punctuation + F-key scancode table
- Window resize events (`SDL_WINDOW_RESIZABLE`)

### UI Toolkit (`lib/ui.eigs` + helpers) — NEW
44-widget retained-mode GUI framework:
- **Containers**: panel, hbox, vbox, scroll_panel, toolbar, tabs, splitter
- **Buttons**: button, toggle_button, toggle, checkbox, radio_group
- **Inputs**: text_input, slider, vslider, knob, spinbox, dropdown, combobox,
  scrollbar, editable_label
- **Data display**: label, table, item_list, tree, chart, bar_chart, gauge,
  meter, progress_bar, badge, code_view
- **Overlays**: dialog, menu, toast system
- **Domain**: grid, piano_keyboard, waveform_view, color_picker, canvas
- **Layout**: statusbar, property_editor (composed)

Features:
- 3 built-in themes (dark, light, high-contrast) with runtime switching
- Flex layout engine (hbox/vbox with gap, padding, alignment)
- Tab/Shift+Tab keyboard navigation with focus ring
- Animation system with 4 easing functions (linear, ease_in, ease_out, ease_in_out)
- Hotkey registration (`register_hotkey of ["ctrl+s", callback]`)
- Right-click context menus
- Clipboard (Ctrl+C/X/V/A) with text selection in inputs
- Drag & drop with drop targets and reorder support
- Modal dialog stack
- Window resize with automatic re-layout

### Standard Library — NEW MODULES
- **`lib/data.eigs`**: DataFrame operations on list-of-dicts — 27 functions
  (df_from_csv, df_select, df_where, df_sort_by, df_group_by, df_join, etc.)
- **`lib/stats.eigs`**: Statistical functions — 18 functions (mean, median,
  std_dev, variance, quantile, histogram, correlation, describe, etc.)
- **`lib/concurrent.eigs`**: High-level concurrency — future, await_all,
  parallel_map, parallel_each, worker_pool
- **`lib/store.eigs`**: EigenStore high-level layer — find, find_one, upsert,
  bulk_put, to_dataframe
- **`lib/ui.eigs`**: UI toolkit (see above)
- **`lib/ui_theme.eigs`**: Theme presets and management
- **`lib/ui_draw.eigs`**: Low-level drawing helpers
- **`lib/ui_layout.eigs`**: Flex layout engine
- **`lib/ui_anim.eigs`**: Tween animation system

### Meta-Circular Interpreter
- **`lib/eigen.eigs` upgraded to full language parity** (892 → 1680 lines):
  dicts, dot access, lambdas, pipes, pattern matching, list comprehensions,
  break/continue, imports, observer interrogatives with real entropy tracking,
  80+ C builtin bridge
- **Debug hook support**: `eigen_set_hook(fn)` — callback before each statement
  with AST node, environment, and line number

### Graphical Debugger — NEW
- **`examples/debugger.eigs`**: Observer-aware graphical debugger using UI toolkit
- Source view with line numbers, breakpoint markers, current-line highlight
- Variable inspector: Name, Value, Type, When, Entropy, dH, Status
- Output console capturing print from debugged program
- Entropy chart tracking average entropy over execution steps
- Run (F5), Step (F10), Continue (F9), Stop controls

### Testing
- **817 tests** (up from 614 in 0.8.1)
- Coverage: eval.c 96.6%, builtins.c 86.0%, eigenscript.c 81.9%
- GC coverage: val_free for all value types (string, list, dict, function)
- Import error path coverage (module not found, parse errors)
- Terminal builtin coverage (screen_*, raw_key)
- EigenStore CRUD + persistence tests
- Concurrency tests (spawn/join, channels, producer/consumer)

## [0.8.1] — 2026-04-17

### New Builtins
- **`monotonic_ns` / `monotonic_ms`**: high-precision monotonic timer via
  `clock_gettime(CLOCK_MONOTONIC)` — sub-millisecond precision, no fork,
  no shell. For per-frame perf instrumentation.

### Runtime
- **System stdlib resolution**: `load_file` and `import` now search
  executable-relative stdlib paths and `~/.local/lib/eigenscript/` as fallback
  after CWD and script-relative paths. Source-tree binaries can find
  `../lib/*.eigs`, installed binaries can find `../lib/eigenscript/*.eigs`, and
  `make install` still copies `lib/*.eigs` to the user-local directory.
  External projects (Tidepool, iLambdaAi) can use stdlib without copying files.

### Documentation
- Gap analysis for real-world program classes (CLI tools, web servers,
  games, data pipelines, ML training)
- ROADMAP.md updated with all completed features by version
- Review findings from 0.8.0 high-level review addressed

### Testing
- 614 tests (up from 614 in 0.8.0 — timer builtins covered by existing
  infra)

## [0.8.0] — 2026-04-17

### Language
- **`unobserved` block**: user-level opt-out of observer tracking. Inside
  the block, numeric assignments to local vars and dict fields mutate the
  existing `Value` in place (identity preserved, `data.num` updated), and
  `update_observer` is skipped. Outside the block, normal observed
  semantics resume unchanged. Nested blocks compose via a depth counter.
  Measurement: ~22% faster on a 200k-iteration mutation hot loop. Covered
  by 8 new tests in `tests/test_unobserved.eigs`. Syntax:
  ```
  unobserved:
      game.px is game.px + game.vx * DT
  ```

### Hardening
- **Refcount GC — unified teardown path**: `free_value` and `value_free`
  collapsed into a single `free_value` that handles all composite types
  (STR, JSON_RAW, LIST, DICT, FN) and uses `val_decref` for child
  teardown. Previously two near-duplicate functions coexisted: one had no
  DICT/FN handling (silent leak when `val_decref` freed a dict), the
  other recursed with the wrong function on dict children (double-free
  risk on shared Values). Unified path is both leak-free and
  sharing-safe. Two regression tests added for shared values across
  lists and dicts.
- **Bitwise builtins — type checks + defined shift semantics**:
  `bit_and/or/xor/shl/shr` now validate both args are `VAL_NUM` before
  dereferencing `.data.num` (previously read a garbage union field on
  type mismatch — undefined behavior). Shift counts masked with `& 31`
  so `bit_shl of [1, 32]` and similar have defined behavior instead of
  relying on x86's natural modulo-shift. Uses `uint32_t` internally with
  a final cast back to `int32_t` for sign preservation. +6 test checks.

### Security
- **Stack buffer overflow in f-string lexer (high)**: `src/lexer.c:206` wrote
  into a 64 KB stack buffer without bounds-checking the accumulator index.
  An f-string literal segment longer than 64 KB would overrun the stack and
  crash (or corrupt adjacent frames). Deployments that accept untrusted
  `.eigs` source are advised to upgrade. Fixed as part of the strbuf
  migration below.
- **HTTP 404 response JSON injection (low)**: `send_404` in `src/ext_http.c`
  interpolated the unescaped request path into the JSON body. A crafted URL
  containing `"` could break the JSON structure. The path is now omitted from
  the response body (server-side logs still record it).
- **HTTP static-file confinement hardened (medium)**: `src/ext_http.c` now
  resolves the candidate path and the configured `static_dir` with `realpath`
  and rejects anything whose resolved prefix is not the root. This replaces
  the previous `strstr(rel, "..")` check and also defends against symlinks
  inside `static_dir` that point outside it. New regression test `HS06b`
  covers the symlink-escape case.
- **Threat model documented in `SECURITY.md`**: clarifies that `.eigs`
  authors are trusted (the runtime gives scripts the same file/process/network
  access the host user has), while the runtime itself must be safe against
  malformed input, crafted HTTP requests, and malicious model files.

### Hardening
- **Overflow-safe allocator helpers**: new `safe_size_mul`, `xmalloc_array`,
  `xcalloc_array`, `xrealloc_array` in `src/arena.c` abort cleanly on
  `nmemb * size` wrap. Migrated multiplicative allocations across
  `model_io.c`, `model_infer.c`, `model_train.c`, `parser.c`, `lexer.c`,
  `eigenscript.c`, `builtins.c`. `tensor_load` now rejects `rows*cols`
  that exceed `INT_MAX` up front.
- **Growable string buffers replace fixed MAX_STR ceilings**: new
  `src/strbuf.c` helper with doubling growth. Adopted by f-string and
  regular-string lexing, `regex_replace`, JSON encoder/parser,
  `value_to_string` (list + dict), and REPL stdin. Strings, regex
  output, JSON, and f-strings now grow with memory instead of silently
  truncating at 64 KB.
- **Dynamic HTTP request buffer**: `src/ext_http.c handle_request` now
  allocates a heap reqbuf that grows via `xrealloc_array`, replacing
  the 1 MB stack array. Default body cap raised from 1 MB → 16 MiB,
  configurable at runtime via `EIGS_HTTP_MAX_BODY`.
- **`strcpy`/`strcat` hardening**: `src/eval.c:164` string concatenation
  rewritten with `memcpy` + pre-computed lengths for consistency with
  the rest of the hardened codebase.
- Deleted `MAX_STR` / `MAX_BODY` / `MAX_HEADER` from `eigenscript.h`
  (no remaining consumers).

### Architecture
- **`builtins.c` split**: tensor code (~990 lines — all `builtin_tensor_*`,
  `builtin_random_normal`, `builtin_numerical_grad*`, `builtin_sgd_update*`,
  `builtin_tensor_save/load` plus their static helpers) moved to new
  `src/builtins_tensor.c`. Cross-TU prototypes live in new
  `src/builtins_internal.h`. `builtins.c` dropped from 3079 → 2091 lines.

### BREAKING
- Default HTTP request body cap rose from 1 MB to 16 MiB. Deployments
  that relied on the 1 MB ceiling as a DoS mitigation should set
  `EIGS_HTTP_MAX_BODY=1048576`.

### Testing
- 4 new large-buffer regression tests (`test_large_strings`,
  `test_fstring_large`, `test_regex_large`, `test_json_large`) that
  would fail against v0.7.0 with silent truncation or stack overflow.

## [0.7.0] — 2026-04-16

### Language
- **Pattern matching**: `match expr: case pattern: ...` with wildcard `_`
- **Pipe operator**: `data |> transform |> sort` — left-to-right data flow
- **Lambda expressions**: `(x) => x * 2` — inline anonymous functions with closure capture
- **Break/continue**: proper loop control flow
- **Dot-assignment**: `config.name is "value"` on dicts
- **Multiline collections**: lists and dicts can span multiple lines
- **Regex builtins**: `regex_match`, `regex_find`, `regex_replace` (POSIX ERE)
- **Import system**: `import math` loads modules into namespaced dicts

### Architecture
- **Source split**: monolithic `eigenscript.c` → `lexer.c`, `parser.c`, `eval.c`, `builtins.c`
- **OOM-safe allocations**: all value constructors use `xmalloc`/`xcalloc` wrappers
- **Recursion depth guard**: `eval_node` checks against max depth to prevent stack overflow
- **Stack protector**: `-fstack-protector-strong` enabled in builds

### Security
- Fixed shell injection in `ls` builtin
- Hardened `strcpy` into fixed-size op fields with `snprintf`
- Reject negative/malformed Content-Length in HTTP server
- Reject out-of-range model dimensions; safe `size_t` casts in weight allocations
- Softmax NaN guard: zero-sum falls back to uniform distribution
- Three stdlib correctness fixes (math, template, test modules)

### Testing
- **552 tests** across 40+ suites (up from 224 in 0.6.0)
- Fuzz testing: 44 edge case + adversarial tests under ASAN+UBSan
- Coverage targets: `make coverage`, `make fuzz`, `make fuzz-run`
- CLI/REPL, HTTP, DB, model extension test suites
- Formal EBNF grammar specification (`docs/GRAMMAR.md`)

## [0.6.0] — 2026-04-16

### Language
- **REPL**: Run `eigenscript` with no arguments for an interactive session
- **Named function parameters**: `define add(a, b) as:` — no more manual `n[0]`/`n[1]` unpacking
- **String interpolation**: `f"Hello {name}, {x * 2}"` — expressions inside braces are evaluated
- **Native dictionaries**: first-class dictionary type with `{}` literals and `.key` access
- **eval builtin**: `eval of "expr"` — evaluate a string as EigenScript at runtime
- Backward compatible: `define foo as:` with single `n` argument still works
- `n` is always available in all functions for compatibility with existing code

### Error Handling
- **try/catch blocks**: `try: ... catch err: ...` — runtime errors are now recoverable
- **throw builtin**: `throw of "message"` — raise errors from user code
- Nested try/catch with re-throw support
- All runtime errors (undefined variable, type error, index out of bounds, etc.) are catchable

### Meta-Circular Interpreter
- **lib/eigen.eigs**: EigenScript interpreter written in EigenScript
- Tokenizer, parser, and evaluator implemented in pure EigenScript
- `eigen_run of source` evaluates EigenScript source strings end-to-end

### Closures
- Functions capture their defining environment (already worked, now documented)
- `make_adder`, `make_multiplier`, factory patterns all work correctly

### Code Quality
- Removed `n` binding bloat from named-param functions
- All 25 stdlib modules converted to named parameters
- Fixed potential snprintf buffer overflow in list-to-string conversion (CodeQL #14-16)
- Added least-privilege permissions to CI workflow (CodeQL #17)

## [0.5.0] — 2025-04-03

Initial public release of the C-native EigenScript runtime.

### Language
- Observer semantics: every value tracks entropy, dH, and trajectory classification
- Six observer states: improving, diverging, stable, equilibrium, oscillating, converged
- `loop while not converged` — observer-driven loop termination
- Functions, conditionals, for/while loops, recursion
- Lists, strings, JSON, type coercion
- `load_file` with script-relative path resolution

### Runtime
- Single statically-linked C binary (~96K)
- Arena memory allocator with mark/reset
- 121 builtins across core, tensor, observer, I/O, and extension modules
- Tensor math: matmul, softmax, relu, numerical gradients, SGD
- Optional extensions: HTTP server, PostgreSQL client, transformer model

### Standard Library (24 modules)
- **Core**: math, list, string, sort, map, set, functional
- **Data structures**: queue (FIFO/LIFO/priority), state (FSM)
- **I/O & data**: io, json, config, template
- **System**: args, datetime, log, validate
- **Networking**: http
- **Testing**: test, format
- **EigenScript-specific**: observer, tensor
- **Application**: sanitize, auth

### Documentation
- Language reference (docs/SYNTAX.md)
- 121 builtins reference (docs/BUILTINS.md)
- Standard library guide (docs/STDLIB.md)
- Error diagnostics (docs/DIAGNOSTICS.md)

### Tests
- 121-test suite covering language features, builtins, and edge cases
