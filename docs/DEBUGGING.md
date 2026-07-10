# Debugging EigenScript

EigenScript's debugging story is built on one property: **the runtime
records its own execution**. Every nondeterministic input lands on a
trace tape ([TRACE.md](TRACE.md)), every assignment feeds a per-name
history, and every binding carries an observer trajectory. Debugging is
therefore mostly *interrogation* — of a live run, or of a recorded one —
rather than re-running and hoping.

The canonical loop:

```
failure  →  replay  →  interrogate
```

1. **Capture the failure as a tape.** `eigenscript --test
   --trace-on-fail tests/` records each test; a failing test keeps its
   tape and prints the exact reproducer line. Or record any run
   directly: `eigenscript --trace run.tape prog.eigs` (the CLI twin of
   `EIGS_TRACE=run.tape`).
2. **Replay it.** `EIGS_REPLAY=run.tape eigenscript prog.eigs` re-drives
   the run with the *same* recorded nondeterminism — same random draws,
   same clock reads, same file bytes. Byte-identical output, first try.
3. **Interrogate it.** Ask the run what happened — from inside the
   program (temporal interrogatives), or from outside (the tape-stepper).

## The tape-stepper: `eigenscript --step`

```
$ eigenscript --step run.tape prog.eigs
tape run.tape: 68 steps, 94 assigns (5 bindings), 1 nondet records
step 1/68  line 9
(step)
```

`--step` opens a recorded tape in an interactive stepper. Nothing
executes — it is a pure *reader* over the tape's line events (`L`),
assignment deltas (`A`), and nondet returns (`N`) — so stepping
**backward is exactly as cheap as forward**: the greyed-out step-back
button incumbent debuggers can't light up is just an index decrement
here. The optional second argument is the source file, shown alongside
each stop.

| Command | Effect |
|---------|--------|
| `s [n]`, Enter | step forward (n lines) |
| `b [n]` | step backward |
| `br <line>` | set a breakpoint (a line filter); `br` lists, `del <line>` removes |
| `c` / `rc` | continue forward / **backward** to the next breakpoint |
| `j <line>` / `jb <line>` | jump to the next / previous stop at a line |
| `p [name]` | bindings at this point: value + trajectory label |
| `t <name>` | one binding's full trajectory up to this point |
| `i` | tape info and current position |
| `q` | quit |

Each stop shows the line, its source text (when the source is given),
and the events that happened during it:

```
step 11/68  line 7
  |     conv is conv / 2
  A conv=256
  A i=2
```

### Trajectories, not just values

`p` shows something no incumbent debugger has: each binding's **observer
trajectory classification** at the current position, computed by the
runtime's own `report_value` classifier (the #294 value channel — see
[OBSERVER.md](OBSERVER.md)) over the assignments seen *so far*:

```
(step) p
osc = -1  [oscillating]  (31 assigns)
conv = 9.5367431640625e-07  [converged]  (31 assigns)
msg = "hello"  (1 assign)
```

Because the label is position-dependent, stepping backward rewinds the
*diagnosis*, not just the values — walk back 40 steps and `conv` reads
`[moving]` again: you can find the exact moment a binding settled, blew
up, or began oscillating. `t <name>` shows the same thing longitudinally,
one row per assignment with the running label.

Labels come from feeding the reconstructed numeric history through the
same `ObserverSlot` machinery the language uses at runtime, so the
stepper's `[converged]` is *by construction* what `report_value of x`
would have said at that moment. Non-numeric bindings show their value
with no label.

### Scope and honesty

- `A` records fire at **every scope** but carry the name only, so
  same-named bindings from different scopes merge into one stream —
  exactly like `state_at` ([TRACE.md](TRACE.md)). A function local named
  `i` and a top-level `i` are one trajectory to the stepper.
- Heap values appear as the tape records them: strings quoted (and
  truncated past the record budget), collections as size markers
  (`<list:3>`, `<dict:2>`), functions as `<fn>`.
- The stepper enforces the #411 version rule exactly as replay does: the
  tape's format and runtime version must match this binary, else it
  refuses with exit 3. A viewer that guessed at a foreign encoding would
  show plausible-but-wrong state — the silent divergence the header
  exists to prevent.

## Temporal interrogatives (in-program)

The language itself can ask historical questions with no tape at all —
the assignment history is always on when the program contains a temporal
query (see [TRACE.md](TRACE.md) for the compile gate, and
[SYNTAX.md](SYNTAX.md) for the grammar):

- `prev of x` — the previous value of `x`
- `what is x at 42` — `x`'s value when line 42 last ran
- `when is x at 42` — how many times `x` had been assigned by then
- `where/why/how is x at 42` — the observer's verdict at that moment
- `state_at of 42` — every binding's value at line 42, as a dict

Under replay these read the *failing* run's history — the interrogatives
and the stepper are two views of the same recorded truth: use
interrogatives when the program should inspect itself, the stepper when
you want to scrub the timeline from outside.

## Choosing a tool

| Situation | Tool |
|-----------|------|
| A test fails in CI | `--test --trace-on-fail`, archive the tape, replay locally |
| A flake you can't reproduce | record with `--trace` until it fires; the tape *is* the repro |
| "When did this variable go wrong?" | `--step`, breakpoint the line, `rc` backward, watch `p`'s label flip |
| A program should react to its own history | temporal interrogatives in the source |
| Meta-circular debugging with a UI | `examples/debugger.eigs` (its own history, not the tape) |

## Roadmap (#418)

This CLI stepper is eigsdap **v1**. Blocked behind it: function-local
frames as first-class scopes (v2) and a DAP server over stdio —
`stepBack`/`reverseContinue` in VS Code with trajectory child nodes in
the variables pane (v3).
