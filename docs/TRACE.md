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

The tape is plain text, one record per line, three record kinds:

| Record | Meaning |
|--------|---------|
| `L <line>` | Source-line event (from `OP_LINE`). Adjacent duplicate lines with no `A`/`N` between them are deduped — the compiler emits per-statement LINEs and bare repeats are noise. |
| `A <name>=<value>` | Assignment delta: a top-level binding changed. |
| `N <fn>=<value>` | Nondeterministic builtin return — the replay-determinism substrate. |

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

## Recorded Builtins

Every builtin whose return value is nondeterministic from the script's
perspective lands on the tape as an `N` record:

- **Random:** `random`, `random_int`, `random_normal`, `random_hex`
- **Time:** `monotonic_ns`, `monotonic_ms`
- **Environment / files:** `env_get`, `read_text`, `read_bytes`,
  `read_bytes_buf`
- **HTTP extension:** `http_post` (success and all error paths),
  `http_request_body`, `http_session_id`, `http_request_headers`

The hook is the `TRACE_NONDET_RET` macro in `src/trace.h`, used at
every nondet return site — adding a new nondet builtin means wrapping
its return in the same macro.

## Replay Semantics

With `EIGS_REPLAY` set, each nondet builtin call takes the next `N`
record from the tape instead of invoking its underlying source. The
contract:

- **Strict ordering.** Records are consumed in tape order. The recorded
  *sequence* of nondet calls is the contract.
- **Lenient names.** If the builtin name doesn't match the record's
  name, a warning is logged to stderr but the recorded value is used
  anyway — names are for human-readable debugging.
- **Graceful exhaustion.** When the tape runs out, replay switches off
  and remaining calls hit the real source.
- **Unparseable records** fall back to the builtin's live source.

All value shapes round-trip: numbers, null, booleans, strings, lists,
dicts, and buffers (including nested containers).

Regression coverage: `tests/test_replay.sh` — each case mutates the
underlying source (e.g. rewrites the file `read_bytes` read) between
record and replay to prove the value comes from the tape.

## Temporal Interrogatives and `state_at`

`prev of x`, the `at <line>` qualifier, and `state_at of line` query a
per-name assignment history (line-stamped, append-only) that is fed by
the same assignment hooks. This history is **independent of
`EIGS_TRACE`** — it is language surface, always on, no tape required.
The tape exists for cross-run reproducibility; the history exists for
in-run time travel.

- History tracks top-level (global) bindings — the same assignments
  that produce `A` records when tracing is on.
- `state_at of line` walks every tracked name's history backward and
  returns a dict of each binding's value at or before `line`. Cost is
  O(names x avg history depth) per call — a backward linear scan per
  name. Snapshot caching is deferred until a real workflow shows the
  scan is a bottleneck.
- Per-assign cost of the history: one cache line + a pointer compare.

Language-level syntax and examples: [SYNTAX.md](SYNTAX.md),
[GRAMMAR.md](GRAMMAR.md).

## Debugger Step-Back

The graphical debugger (`examples/debugger.eigs`) offers F8/F11
history navigation while paused. That layer does **not** read the
trace tape: the tape tracks host-VM globals, and the meta-circular
interpreter has its own env dict — so the debug hook captures its own
`(line, env-snapshot)` pairs per statement, FIFO-capped at 10 000
steps.
