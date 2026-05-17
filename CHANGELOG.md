# Changelog

All notable changes to EigenScript are documented here.

## [Unreleased]

### Language
- **Compound assignment operators**: `+=`, `-=`, `*=`, `/=`, `%=`, `&=`,
  `|=`, `^=`, `<<=`, `>>=`. Desugared in the parser to existing AST nodes —
  `eval_num_fast` handles them for free. Works on variables, dot-access,
  and index-access.
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
- `sign_extend of [val, bits]` — sign-extend a value from a given bit width
- `scan_ints of text` / `scan_ints of [text, comment_marker]` — C-backed scan
  of whitespace-delimited signed integer tokens, optionally skipping comment
  lines
- `sort of list` — in-place qsort on numeric lists
- `read_bytes_buf of path` — read binary file as VAL_BUFFER (zero per-element alloc)
- `gfx_fb of [buf, w, h, x, y, scale]` — blit a buffer as a scaled texture
- `ppu_render_frame of [mem_buf, fb_buf]` — full Game Boy PPU rendering in C

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
