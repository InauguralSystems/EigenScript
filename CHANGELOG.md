# Changelog

All notable changes to EigenScript are documented here.

## [0.13.0] — unreleased

A language-features release.

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
  test_store 14→22), JSON escape branches JH32–JH43 (`\n \r \t \/ \\`
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
emission of lists/dicts/buffers, strings escape `\"`, `\\`, `\n`, `\r`,
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
