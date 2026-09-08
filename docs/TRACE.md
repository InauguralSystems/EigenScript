# EigenScript Trace & Replay

EigenScript can record its own execution to a tape and play it back.
The tape captures every nondeterministic input a run consumed, so a
replayed run produces byte-identical output: the same random sequence,
the same `monotonic_ns` timestamps, the same HTTP responses.

Two environment variables control it:

| Variable | Effect |
|----------|--------|
| `EIGS_TRACE=<path>` | Record: open `<path>` for writing and log line, assignment, and nondet events |
| `EIGS_REPLAY=<path>` | Replay: open a previously recorded tape and serve its nondet values to builtins in order |

```
$ EIGS_TRACE=run.tape eigenscript sim.eigs > first.out
$ EIGS_REPLAY=run.tape eigenscript sim.eigs > second.out
$ diff first.out second.out        # identical
```

Both are off by default. The disabled cost at each hook site is one
predicted-not-taken load + branch.

## Tape Format

The tape is plain text, one record per line, six record kinds:

| Record | Meaning |
|--------|---------|
| `V <format> <runtime>` | Version header — always the first record (e.g. `V 3 0.43.0`). Stamped once per tape-open; a journal appended across sessions carries one per session. See [Format Versioning](#format-versioning-411). |
| `L <line>` | Source-line event (from `OP_LINE`). Adjacent duplicate lines with no `A`/`N` between them are deduped — the compiler emits per-statement LINEs and bare repeats are noise. |
| `S <fn> <depth> <serial>` | Scope transition (#539 v2): the `A` records that follow belong to this frame instance — `<fn>` is the chunk name (`<module>`, `<lambda>`, or the function name), `<depth>` the 0-based frame depth, `<serial>` a per-thread monotonically increasing frame-instance id stamped at frame push. Emitted lazily with the same dedup discipline as `L`: only when the frame owning the next assignment differs from the last `S`, so the byte cost lands at call boundaries that actually assign. Two invocations of the same function carry different serials — their local streams never merge. Skipped on replay; folded by `--step`. |
| `A <name>=<value>` | Assignment delta: a binding changed. Fires at **every scope** — function locals included — and is scope-qualified by the preceding `S` record, so a function-local `i` and the top-level `i` are separate streams (`--step` resolves names innermost-first along the reconstructed call chain, with shadowing). |
| `N <fn>=<value>` | Nondeterministic builtin return — the replay-determinism substrate. |
| `O cfg <dh_zero> <dh_small> <h_low> <window> <scale>` | Observer configuration in force (v3). Written whenever the state's observer knobs differ from what the tape last said, immediately before the next `L`/`A` record. See [Observer Configuration](#observer-configuration-1044-1045). |
| `O win <name> <n>` | Per-binding observer window override (v3) — `set_observer_window of ["name", n]`; `n == 0` clears it. |

### Value serialization

`N` records are written with full fidelity so they can be parsed back
into real values on replay:

- Numbers, `null`, and booleans are written verbatim.
- Strings are double-quoted; `\"`, `\\`, `\n`, `\r` are escaped, other
  control/non-printable bytes become `\xNN`.
- Lists and dicts are emitted recursively: `[1, 2, 3]`,
  `{"key": value}`.
- Buffers get a leading `b` — `b[1,2,3]` — to disambiguate from lists.
- Each record has a 64 KiB byte budget. On overflow the record ends
  with a `…<truncated:RESIDUAL>` marker so partial records remain
  visually parseable (truncated records are not replayable; the builtin
  falls back to its live source).

## Derived, Not Recorded: The Scheduler Trace (#846)

The cooperative task scheduler's decision history (`task_sched_trace`, see
docs/CONCURRENCY.md) is **not** an `N` record. The interleaving is a pure
function of program order and `task_sched_seed`, so a replayed run
re-derives the identical history from the same schedule; recording it would
create a second source of truth that could disagree with the first.
`tests/test_task_sched_trace.sh` asserts the tape's `N`-record count is
unchanged by arming the trace and that record → replay yields the same
history on both tiers.

## Recorded Builtins

Every builtin whose return value is nondeterministic from the script's
perspective lands on the tape as an `N` record:

- **Random:** `random`, `random_int`, `random_normal`, `random_hex`
- **Time:** `monotonic_ns`, `monotonic_ms`, `clock_unix` (#683)
- **Environment / files:** `env_get`, `read_text`, `read_bytes`,
  `read_bytes_buf`, `read_line` (stdin, #558), `is_dir` (#576),
  `file_exists`, `ls`, `getcwd`, `exe_path`, `mkdir` (#585).
  `mkdir` is a *write* whose return (a success bit) is filesystem-dependent:
  it is Recorded rather than #148-non-replayable because that bit **is**
  pinnable by the tape (unlike a subprocess fd). Under `EIGS_REPLAY` the
  `TAKE` short-circuits before the `mkdir(2)` calls, so the recorded bit is
  served and the directory is **not** created a second time — replay does not
  re-run the side effect, the same rule as the subprocess/audio boundary.
  `read_bytes_buf`'s over-cap **raise** (#601) also rides the tape: the
  observed file size is recorded as a `VAL_NUM` `N` record (unambiguous —
  success records a `VAL_BUFFER`, open-failure records null) and the
  identical `io` error is re-derived from it under `EIGS_REPLAY`, so an
  over-cap failure replays byte-identically with no live fs access
- **Process:** `args` (command-line arguments — differ across
  invocations, so the recorded list is served on replay regardless of
  the live argv; #471)
- **HTTP extension:** `http_post` (success and all error paths),
  `http_request_body`, `http_session_id`, `http_request_headers`
- **Network extension (#414):** `net_listen`, `net_port`, `net_accept`,
  `net_dial`, `net_recv`, `net_send`. Every environment outcome is a
  recorded *value* — `null` for failure/timeout, a number or buffer for
  success — never a live-path-only raise, so a `catch` cannot desync
  the record stream (the `read_bytes_buf` lesson). The whole family is
  TAKE/RECORD-wrapped: under `EIGS_REPLAY` the tape is taken **before
  any socket call** — the replay run creates, binds, connects, reads,
  and writes **nothing** (verified by strace: zero socket-family
  syscalls), which is what "replay last night's flaky network failure
  with the network gone" means. `net_recv` caps at 8192 bytes per call
  so every `N` record fits the 64 KiB budget, the same discipline as
  `audio_capture_read`. `net_send` is a *recorded write*, like `mkdir`:
  its observable effect on the program is its result (bytes sent), and
  the peer's future responses are themselves on the tape — so under
  replay the send is **suppressed** (recorded count served, nothing
  written) and the replayed world stays consistent. That is the
  deliberate contrast with the #148 subprocess family below: a
  `proc_write` feeds a live child whose behavior the tape does not pin,
  so suppressing it would be meaningless. (`net_close` is deterministic
  and untraced — under replay no socket exists and it is a natural
  no-op, the `audio_capture_close` shape.)
- **Model extension (#960):** `eigen_generate`. Sampling at temperature
  above 0 draws from the shared `drand48` stream, so the emitted token list
  is a nondeterministic return — untaped, a generating program could not be
  replayed at all. **One record per call carries the whole token list**, not
  one per sampled position: the draws are an implementation detail of the
  decoding policy (top-k and top-p consume different numbers of them), the
  list is what the script observes. TAKE/RECORD-wrapped, so `EIGS_REPLAY`
  serves the tokens *before the model is consulted* — a recorded generation
  replays with no checkpoint on disk and without advancing the RNG. Every
  return is recorded, argument errors and the no-model-loaded empty list
  included, so a program that hits one cannot desync the stream. Greedy
  (`temperature < 0.01`) calls ride the same path: the tape cannot show
  which branch ran, and replay may not load a model to re-derive it.
- **Rendered pixels (gfx extension, #823):** `gfx_read`. Renderer output
  depends on the font rasteriser, the driver and the backend, so the pixel
  a render-decode oracle reads back is a device input and takes the
  TAKE/RECORD pair.
- **A REJECTED argument consumes no record** (#1007). `audio_capture_open`,
  `audio_capture_read`'s siblings and `gfx_read` all place their
  argument-type guard *above* `TRACE_NONDET_TAKE`, because an argument's
  type is deterministic and so a rejected call is not a nondeterministic
  input. Placed below the TAKE, the capture run returns before
  `TRACE_NONDET_RECORD` and writes nothing while the replay run's TAKE still
  consumes one — every later record for that name shifts by one and the
  rejected call replays as a real device id or a real pixel, silently, even
  under `EIGS_STRICT=1`. Measured on `audio_capture_open` before the guard
  was hoisted: capture printed `0 2 null`, replay of that same tape printed
  `2 2 null`. Suite section `[133]` pins it.
- **Audio capture (gfx extension, #579):** `audio_capture_open`,
  `audio_capture_read`. Captured audio is a device input, so the whole
  capture chain is TAKE/RECORD-wrapped: under `EIGS_REPLAY` the tape is
  taken *before any SDL call* — replay never opens or reads a real
  microphone; the recorded device id and sample buffers (the `b[…]`
  encoding) are served instead. `audio_capture_read` returns at most
  2048 samples per call precisely so every `N` record fits the 64 KiB
  record budget — an over-budget record would be `…<truncated>` and
  replay would silently fall back to the live microphone. Drain loops
  ("read until empty") replay faithfully: one record per call, empties
  included. (`audio_capture_close` is deterministic — always `null` —
  and untraced; under replay it is a no-op because no device was
  opened.) The audio *output* device (`audio_open`) is deliberately
  untraced: playback is a side effect that replay re-performs live,
  like `print`. The residual gap — `audio_open`'s
  environment-dependent return (`0` on a machine with no audio) can
  steer a branch differently on replay — is accepted for now; closing
  it would change how existing tapes replay.

The hook is the `TRACE_NONDET_RET` macro in `src/trace.h`, used at
every nondet return site — adding a new nondet builtin means wrapping
its return in the same macro. A builtin that *builds* its return value
(a list, buffer, or dict) before returning uses the `TRACE_NONDET_TAKE`
/ `TRACE_NONDET_RECORD` pair instead (`args` does): the early `TAKE`
short-circuits under replay before the value is built, so the live
construction is neither run nor leaked.

## Observer Configuration (#1044/#1045)

A trajectory verdict — `report of x`, the six predicates, the trajectory
labels `--step` and the DAP server print — is a function of the
**assignments** and of the **observer configuration**: three thresholds
(`set_observer_thresholds`), the window depth (`set_observer_window`, per
state and per binding), and the characteristic scale
(`set_observer_scale`). The tape carried the assignments and not the
configuration, so a recorded run stepped back classified at the *state
defaults* and printed a verdict the live run never gave:

```
u is 0.0
set_observer_window of ["u", 50]        # a 46.9-sample period needs 50
loop while t < 200:  u is 272.4 + 10.0 * (cos of (6.28318 * t / 46.9)) …
print of (report of u)                  # live: oscillating
```
```
$ eigenscript --step u.tape u.eigs      # before: [diverging]  ← never happened
```

A debugger that confidently prints the wrong verdict is exactly the
fail-soft shape this language refuses, so the configuration rides the tape:

- **`O cfg`** carries the five state-level scalars. It is emitted **by
  diff**, not from the knob builtins: the writer compares the state's live
  configuration against what the tape last said and emits a record when they
  differ, immediately before the next `L` or `A` record. So the tape carries
  the configuration *in force* by construction — one set by an embedder
  before the run, by a second `EigsState`, or by a knob nobody remembered to
  instrument still lands on the tape. A program that never moves a knob
  writes no `O` records at all.
- **`O win`** carries the per-binding window override, which lives on an
  `Env` slot rather than on the state and so has no cheap diff. It is
  written from `set_observer_window` at the point of the call, preceded by
  its own frame's `S` record — the override belongs to the frame that
  *resolved the name*, and that frame may not have assigned anything yet
  (widening a parameter's window before the body writes it), so the scope
  transition cannot be left to the next `A` record.
- Both are recorded **as events, in place**, not stamped into the header.
  That is the whole point: a program that changes a knob **mid-run** — one
  phase `moving`, the next `converged` — steps back correctly at both
  stops, which a header snapshot could only have refused.
- `tape_read.c` is the one reader (`--step` and the DAP server share it):
  it installs the compiled-in defaults, then applies every `O` record that
  precedes the assign it is folding, and restores the caller's own
  configuration when the fold ends. A reader never leaks a tape's knobs
  into its own state.
- **The configuration is folded to the STOP, not to the last assign.** The
  knobs split by when the runtime consumes them: the window and the scale are
  read while a value is being *recorded*, the three thresholds (and the window
  again, for the full-window certifications) while a verdict is being
  *reported*. So a knob moved after a binding's last assign and before the
  stop still changes what `report of x` says there — and folding only up to
  the last assign printed `stable` where the live run printed `converged`:

  ```
  x is 1000.0 / d is 5.0 … loop 30x: x is x + d ; d is d * 0.99
  set_observer_thresholds of [0.01, 0.02, 0.1]
  print of (report of x)                    # live: converged
  ```
  ```
  $ eigenscript --step after.tape after.eigs      # `p x`
  x = 1130.1498133058592  [stable]     ← before: the record was on the tape,
                                          in force at the stop, and skipped
  ```

  `tape_traj_settle` walks the configuration cursor on to the stop position
  and re-reads the label, so `p`/the DAP binding cell answer "what would
  `report of x` say **here**". The `t` view's rows stay per-moment by
  construction — a row is the label after *that* assign — so when the settled
  label differs, it gets a line of its own ("observer configuration changed
  after the last assign — at this stop: [converged]") rather than letting the
  last row speak for the present; the DAP shows the same as a `#now` row.
- **A corrupt `O` record is refused, not installed.** The reader puts these
  values into its own observer state, so `O cfg … 0 …` divides by zero sizing
  the value ring and a negative or 4e9 window asks `calloc` for 2^64−1 bytes.
  Every field is therefore checked at parse time against exactly the
  invariants the live builtins enforce — window in `[4, 64]` (plus the `O win
  <name> 0` clear form), positive thresholds with `dh_zero < dh_small`,
  positive finite scale — and a record
  outside them refuses the tape with exit 3 (`tape observer-configuration
  record is not one this runtime could have written …`). Tapes travel in #413
  attached-tape bundles, so this is the torn-archive rule applied to the
  configuration. Clamping was rejected: a clamped window is a configuration
  the recording run never had, so the label would still be a confident lie,
  just a different one.

**Replay is unaffected**, and deliberately so: `EIGS_REPLAY` re-executes the
program, so the program's own knob calls run again in the same order. The
`O` records are for readers that reconstruct state *without* executing —
the stepper, the DAP server, and anything else that folds `A` records into
an `ObserverSlot`.

**`O win` names a BINDING, not a name.** The live call resolved the binding
innermost-first from its own frame; the reader resolves it the same way from
the frame instance the record was written in (the tape's `S` records give the
chain) and applies the override to that history **by identity** — never by
name equality. This matters because one name is routinely several bindings on
one tape: two invocations of a function are two frame instances, and a
function-local can share a name with a module-level global. Matching by name
made `--step` print `oscillating` for a binding whose live run said
`diverging`, which is the same fail-soft shape the `O` records exist to
remove. `tests/test_tape_observer_config.sh` section 8 pins all four shapes
(leak forward, correct application, a parameter widened before its frame
assigns, and a module-level binding assigned after the call).

**Residual — a name the call chain cannot reach.** The reader walks the
frame's `S`-record parents, which is the *call* chain; a closure's
environment parent is its definition site instead, so an override set on a
captured name may resolve to nothing. When it does, the reader applies the
record only if exactly one history on the whole tape carries that name (then
it can only mean that binding); otherwise it drops the override, and the
stepped verdict is the default-window one. It never sprays the override
across same-named bindings — losing a knob shows a *different* label than the
live run, applying it to the wrong binding shows a *confident wrong* one, and
only the second is the shape this design refuses to ship.

## Non-Replayable Builtins (issue #148)

Some nondet builtins are *not* wrapped, and **fail loudly** when
called under `EIGS_REPLAY`. They sit on the wrong side of the replay
boundary because the tape's recorded return value does not pin down
the host-side causal structure the call depends on — re-running the
underlying source under replay would re-execute real side effects
that the original tape neither captured nor re-creates:

- **Subprocess streaming I/O:** `proc_spawn`, `proc_write`,
  `proc_read_line`, `proc_read`, `proc_close`, `proc_wait`.
  Replaying a recorded fd is meaningless — the child process from
  the recorded run does not exist; forking a fresh one would change
  the world a second time.
- **Bulk-output exec:** `exec_capture` — same reason. The tape
  carries the captured stdout, but the child fork would still happen,
  and its real side effects (writes outside the captured pipe, file
  changes, network calls) would re-run.
- **Concurrent channel receive:** `recv`, `try_recv`, `recv_timeout`.
  Channel ordering depends on the live scheduler — replay against a
  tape with a different interleaving would deadlock or silently
  diverge.

These builtins raise a catchable runtime error under
`EIGS_REPLAY`, with the message format
`"<fn>: not replayable under EIGS_REPLAY (subprocess/concurrency
boundary; see docs/TRACE.md)"`. Programs that need to be replay-safe
must guard these call sites or avoid them entirely.

A boundary refusal is a **clean exit, never a signal**: uncaught, it ends
the program with exit status 1 like any other runtime error; caught, the
program continues. That holds on every thread — a refused `recv` on a
`spawn`ed worker that runs the builtin directly (`spawn of [recv, ch]`)
used to die by SIGSEGV after printing the diagnostic (#1112: the worker
has no VM, and the uncaught-error printer dereferenced it); it now prints
the diagnostic and the process exits 1, because an uncaught death on a
worker fails the run (docs/SPEC.md "Concurrency"). A signal exit under
`EIGS_REPLAY` is a runtime bug, and `tools/replay_diff.sh` — the
same-binary record/replay differential CI runs over the whole corpus —
fails on any signal exit in either arm regardless of what the arm
printed; the diagnostic text never excuses a crash.

## Replay Semantics

With `EIGS_REPLAY` set, each nondet builtin call takes the next `N`
record from the tape instead of invoking its underlying source. The
contract:

- **Strict ordering.** Records are consumed in tape order. The recorded
  *sequence* of nondet calls is the contract.
- **Lenient names.** If the builtin name doesn't match the record's
  name, a warning is logged to stderr but the recorded value is used
  anyway — names are for human-readable debugging. Set
  `EIGS_REPLAY_STRICT=1` to make a mismatch fatal instead: the
  process reports the divergence and exits with status 3. Use it in
  harnesses where tape/program drift should fail loudly rather than
  produce a subtly wrong replay.
- **Graceful exhaustion.** When the tape runs out, replay switches off
  and remaining calls hit the real source.
- **Unparseable records** fall back to the builtin's live source.

All value shapes round-trip: numbers, null, booleans, strings, lists,
dicts, and buffers (including nested containers).

Regression coverage: `tests/test_replay.sh` — each case mutates the
underlying source (e.g. rewrites the file `read_bytes` read) between
record and replay to prove the value comes from the tape.

## Every Failure is a Tape (`--test --trace-on-fail`)

Dynamic typing surfaces errors at runtime; deterministic replay converts that
weakness into a capability no incumbent ships — every failing test arrives as a
byte-identical reproducer.

```
$ eigenscript --test --trace-on-fail tests/
  FAIL  tests/test_solver.eigs  (exit 1)
        roll: 0.297357521
        replay: EIGS_REPLAY=/tmp/eigen_bNGhgd eigenscript tests/test_solver.eigs
```

`--test --trace-on-fail` records each test into its own tape (`--trace <path>`,
the CLI twin of `EIGS_TRACE`). A passing test discards its tape; a failing one
keeps it and prints the exact `EIGS_REPLAY=<tape> …` invocation. Running that
line re-drives the failure with the *same* recorded nondeterminism — the random
draw, the clock read, the file bytes — so a flake reproduces on the first try.

The canonical loop: **failure → replay → interrogate**. Once you are replaying
the exact run, the temporal interrogatives read its history — `prev of x`,
`state_at`, and the `--step` tape-stepper ([DEBUGGING.md](DEBUGGING.md)) — so
you inspect the trajectory that actually failed, not a fresh one that might
not. The stepper reads the tape directly (no replay needed): step
forward/back over its L records, reconstruct bindings from its A records,
and watch each binding's observer-trajectory label at any point.

Under `--json`, each result carries a `"tape"` field for CI to archive as an
artifact; the human form prints the replay line.

**Same-version enforcement.** A tape is a reproducer for the EigenScript
version that recorded it, and since #411 the runtime enforces that
mechanically: replaying an archived tape after a version bump refuses loudly
instead of silently diverging (see [Format Versioning](#format-versioning-411)).
Archiving jobs need only keep the tape — it names its own version on line 1.
`EIGS_REPLAY_STRICT=1` additionally turns any record/replay *name* mismatch
into a loud abort.

## Format Versioning (#411)

The tape is a persisted artifact — CI archives failure tapes, bundles may
carry one, embedders journal them — so it names its own provenance. **The
decision: version-stamped tapes, refuse-on-mismatch. There is no
compatibility promise, ever** — a tape is valid for exactly the format
*and* runtime version that recorded it, matching the no-backcompat policy
everywhere else in the runtime (version-and-reject, never migrate).

- Every tape's first record is `V <format> <runtime>`. The format integer
  (`TRACE_FORMAT_VERSION` in `src/trace.h`) bumps on **any** change to the
  tape encoding; the runtime string is the recording binary's version.
  History: **v2** (#539) added the scope-transition `S` records; **v3**
  (#1044/#1045 follow-up) added the observer-configuration `O` records.
  A v2 tape cannot say what its knobs were — the calls simply are not on it
  — so the compat decision for the bump is the standing one, and it is the
  loud half: a v2 tape is **refused** by `--step`, by the DAP server and by
  `EIGS_REPLAY` with exit 3, never classified at the defaults and presented
  as the recorded run. Coverage: the `v2 (pre-O-record) tape is refused`
  cases in `tests/test_tape_observer_config.sh`.
- On replay, a missing header, a malformed (torn) header, a different
  format version, a different runtime version, an empty tape, or an
  unopenable `EIGS_REPLAY` path each refuse loudly — hosted replay exits
  with status 3 (the replay-divergence status), and `eigs_set_replay_tape`
  returns 0 without installing the tape. Replay never falls back to a
  live run: the user asked for a replay, and a plausible-looking live run
  is exactly the silent divergence the header exists to prevent.
- Mid-stream `V` records are legal (a journal appended across sessions
  carries one per session) but each must match, or replay aborts. The
  embed seam validates **every** session header at install time, so a
  mixed-version journal is refused up front (return 0, the previously
  installed tape left untouched) rather than aborting the host mid-run;
  the mid-stream abort therefore only fires for `EIGS_REPLAY` files.

```
$ EIGS_REPLAY=old-v0.26.0.tape eigenscript sim.eigs
trace: tape recorded on EigenScript 0.26.0, this binary is 0.27.0 —
refusing to replay; a tape is valid only for the version that recorded
it (docs/TRACE.md)
$ echo $?
3
```

There is no override flag. The tape is plain text: if you are certain a
tape is valid for this binary (say, two dev builds of the same tree),
editing line 1 is the override — a deliberate, visible act. The residual
honesty gap runs the other way: version *equality* is necessary, not
sufficient. Two different dev builds can share the string `dev` (or an
unreleased version), and the header cannot tell them apart — release
boundaries are enforced; dev builds are on their honor.

Regression coverage: the `version refuse` cases in `tests/test_replay.sh`
plant each mismatch class (format, runtime, missing header, empty file)
and require the exit-3 refusal. `tests/test_tape_observer_config.sh`
additionally carries a REAL pre-v3 tape — `tests/fixtures/tape_v2_baseline.tape`,
recorded by the v0.43.0 release binary — and requires the same exit-3 refusal
from both `--step` and `EIGS_REPLAY`. That refusal is the deliberate answer to
"an old tape should still step": a v2 tape carries no `O` records, so stepping
it would classify at the defaults and print a verdict the recorded run never
gave. The knobs are exactly what the format bump exists for, so a tape that
predates them is re-recorded, not reinterpreted.

## Temporal Interrogatives and `state_at`

`prev of x`, the `at <line>` qualifier, and `state_at of line` query a
per-name assignment history (line-stamped, append-only) that is fed by
the same assignment hooks. This history is **independent of
`EIGS_TRACE`** — it is language surface, always on, no tape required.
The tape exists for cross-run reproducibility; the history exists for
in-run time travel.

- History tracks assignments at **every scope**, function locals
  included — exactly the assignments that produce `A` records when
  tracing is on. Entries are keyed by name only (no scope qualifier),
  so `state_at` merges same-named bindings from different scopes into
  one stream, and a query can see a local of a function that has
  already returned.
- Recording is compile-gated: the compiler enables it when the program
  contains `prev of`, any `at <expr>` qualifier, or a reference to
  `state_at` (and `EIGS_TRACE` enables it unconditionally). Programs
  with no temporal queries pay nothing per assign — profiling showed
  the previous always-on recording cost roughly a third of a
  dispatch-heavy workload's runtime. Since a program cannot observe
  history without containing a query, the gate is invisible — with one
  edge: code compiled mid-run (`eval`, REPL) that introduces the
  *first* temporal query starts recording at that point, so assigns
  executed earlier are not visible to it. Aliasing `state_at` through
  a dict or eval-built string also hides it from the compiler's scan.
- The gate is **per name**, not whole-program (#827). Both history-reading
  forms — `prev of x` and `<kw> is x at L` — compile to a NAMED opcode
  carrying a compile-time identifier, so the set of names a temporal query
  can ever reach is known exactly, and assignments to any other name record
  nothing. This is what stops a `prev of v` sitting in a function nothing
  ever calls from taxing every assignment in the program. Three things
  force the wildcard instead, because they can reach a name the compiler
  cannot enumerate: `state_at` (it queries every tracked name), an open
  tape (`EIGS_TRACE` or an embed sink), and turning recording on without
  naming a name (the REPL, `record_history of 1`). Arming only ever widens
  within a session — a name armed mid-run by `eval` starts recording from
  that point, the same edge the whole-program gate already had.
- **Arming is an optimization, and it applies only to the bytecode
  compiler's own chunks** (#830). The narrowing above is sound because a
  compile-time scan enumerated the names; nothing else in the process can
  populate that set. The bytecode compiler is *not* the only producer of
  EigenScript programs, though — the AOT (sibling `ouroboros` repo) emits C
  that calls `trace_assign` directly, an embedder can drive the same seam,
  and `vm_run_bytecode` / `sandbox_run` assemble a chunk from a descriptor.
  v0.35.1 filtered those producers on a set they never fed, so their
  assignments recorded nothing and every `prev of` / `at`-qualified read
  answered `null` — a silent wrong answer, in a public release, that the
  whole suite missed because no test exercised a non-compiler producer.
  The rule now follows the chunk's provenance:

  - `trace_assign(name, slot)` is the producer-facing entry point and
    **records unconditionally**. Any new producer gets correct temporal
    reads by calling it and nothing else; there is no arming ritual to
    remember, and no way to be silently wrong by forgetting one.
  - `trace_assign_filtered(name, slot)` is the narrowed twin, used only by
    the VM/JIT assignment hooks and only when the running chunk carries
    `EigsChunk.compiler_scanned` — i.e. the compiler produced it and armed
    its names. A descriptor-assembled chunk does not carry it, so it
    records every name.

  Retention is bounded by the pruning below in either case, so nothing here
  can bring back the unbounded growth #827 fixed: this filter has only ever
  been a per-assign CPU saving. Coverage lives in
  `tests/test_temporal_producers.eigs` (suite `[70e]`, the descriptor
  producer) and `src/embed_smoke.c` (`make embed-smoke`, the AOT's exact
  C-level shape, with no source compiled anywhere in the process).
- When the compiled program contains a `where`/`why`/`how ... at`
  query, each history entry also stamps an observer snapshot
  (entropy, dH) at assign time, so the observer-derived
  interrogatives answer historically with exactly what a live query
  at that moment would have returned. The capture is compile-gated:
  no such query in the program, no per-assign cost.
- `state_at of line` walks every tracked name's history backward and
  returns a dict of each binding's value at or before `line`.
- **A backward query is TEMPORAL, not line-keyed.** `<kw> is x at L`
  returns the value from the most recent assignment whose line is `<= L`
  — which is *not* "the value at the greatest line `<= L`". Assign at
  line 12, then at line 5, then ask at L=15: the answer is the line-5
  value, because that assignment happened later. Any representation that
  keys the history by line answers the line-12 value and is wrong.
- **The history is bounded by the program TEXT, not by runtime** (#827).
  It used to be append-only and uncapped, holding a reference to every
  value ever assigned: a program that merely mentioned `prev of` grew
  linearly until the machine died. It is now pruned at append time, with
  no change to any answer, because most entries are provably unreachable:

      entry i is dead  <=>  some later entry j has line[j] <= line[i]

  (any `L` that admits `i` also admits `j`, and `j` wins for being later).
  What survives are the strict suffix minima of the line sequence, so the
  live entries are sorted by line and can never outnumber the distinct
  source lines that assign that name. A loop that reassigns one name a
  billion times keeps ONE entry — and pins one value instead of a billion.
  Two facts that pruning would otherwise lose are carried explicitly, so
  the answers are identical: each live entry stores its own
  execution-order predecessor (`prev of x at L` wants a value that is
  usually pruned), and a per-name `(line -> count)` histogram carries
  `when is x at L`, which counts pruned assignments too.
  **Nothing about the tape changed**: `A` records are written by
  `trace_assign` independently of the history table, one per assignment
  as before, and an open tape arms every name anyway. Tapes recorded
  before and after #827 are byte-identical, so no format-version bump
  (#411) — this was a retention bug, not a format one.
- Backward queries (`at`, `state_at`) are therefore a binary search over
  a line-sorted array — `O(log D)` where `D` is the number of distinct
  assigning lines. This replaced the periodic line-floor segment index,
  which existed only to make scanning an unbounded array survivable.
- **`when <n>` addresses an occurrence, and needs its own storage** (#868).
  The pruning above is exactly what makes a loop body unaddressable: the
  surviving entry for a line assigned N times is the Nth, so `what is x at
  <body line>` answers the last iteration and the other N-1 are gone. That
  is correct for a line-keyed question and useless for the question people
  actually ask ("what was `x` on iteration 2"). Source lines are the wrong
  address space for it — not injective over executions, and shifted by any
  edit above the query.

  So `<kw> is x when <n>` indexes the **nth recorded assignment**, and rides
  a separate per-name **ring buffer** that survives the pruning. Its bound is
  a fixed window rather than reachability: the last `EIGS_OCC_WINDOW`
  assignments (default 256) per armed name, so retention is again independent
  of how long the program runs. Memory is `window x armed names`, and the
  ring pins that many values — which is why the arming tier below is the
  narrowest of the three.

  The two empty answers are deliberately different. An ordinal that has not
  happened yet is `null`; one that aged out of the window **raises**. They
  cannot share a representation: the runtime *had* the evicted value and
  dropped it to stay bounded, and reporting that as `null` would be a
  confident wrong answer rather than a missing one.

  The ordinal space is the history's own recorded-assignment counter, and
  the unqualified `when is x` now reports the same number (#908). It did
  not always: `env->assign_counts` skipped assignments made inside an
  `unobserved:` block while the history counted them, so the two disagreed
  by exactly that many and an ordinal computed from `when is x` was short
  by the same amount. Resolving it downward was not open — this form has to
  index what was actually recorded, because that is the only counter that
  can address a stored entry, and dropping unobserved assignments from the
  ordinal space would leave a hole in it: the write happened, its value is
  retained and readable, and it would have had no address. So the count
  came up to the history instead, at both the interpreter and JIT bump
  sites. The two counters are still two (one per-binding in the env, one
  per-name in the history table, and the env's is maintained only on the
  slow write paths the compiler forces interrogated names onto) — they are
  now required to agree.
- **Occurrence arming is the third and narrowest tier** (#868). A name gets a
  ring only if a `when`-qualified query named it at compile time. Unlike the
  line-history arming there is no wildcard: `state_at`, an open tape, and
  `spawn` all widen the history to every name, and letting them widen this
  too would put a ring on every binding in the program — the whole-program
  over-arming #827 was filed about, reintroduced by the back door. Those
  forms are all line-keyed and answer fine from the pruned history.
- Per-assign cost of the history: one cache line + a pointer compare,
  plus the pop-while that retires the entries the new assignment kills
  (amortized O(1) — an entry is pushed once and popped once).
- **The history is per-thread; the tape is per-process** (#739). The
  history table is keyed by *interned name pointer*, and the intern
  table lives on `EigsThread`, so two threads' `x` were never the same
  key — per-thread is the only scope on which the table is coherent,
  and it needs no lock because only its owning thread touches it. It is
  released by `eigs_thread_detach` (and by `trace_shutdown` for the
  process owner's own thread, which must run before the global env dies
  — the slots it drops can reach the env).
- **`trace_shutdown()` is process-wide and a worker must never call
  it.** It closes the one tape, drops the embed sink, and shuts down
  the replay reader. Every `ext_http` connection worker used to call it
  on finishing a request: the first request served closed the tape, so
  every later request's records were silently dropped (measured: one
  record for four hundred requests), an embedder's sink was
  unregistered by whichever request arrived first, and prev-table slots
  recorded by other still-live threads were decref'd. A worker that
  wants to clean up after itself wants `trace_thread_release()`, which
  touches only its own history. Nothing about the tape *encoding*
  changed here, so no format-version bump: this was an ownership bug,
  not a format one.

Language-level syntax and examples: [SYNTAX.md](SYNTAX.md),
[GRAMMAR.md](GRAMMAR.md).

## Debugger Step-Back

The graphical debugger (`examples/debugger.eigs`) offers F8/F11
history navigation while paused. That layer does **not** read the
trace tape: the tape tracks host-VM globals, and the meta-circular
interpreter has its own env dict — so the debug hook captures its own
`(line, env-snapshot)` pairs per statement, FIFO-capped at 10 000
steps.
