# Error provenance and cause chains (#2166)

## Status and current behavior

This is a design, not an implementation. It adds neither an exception
hierarchy nor `finally`. Today a built-in failure is lazily materialized for a
handler as the ordinary dictionary `{kind, message, file, line}`
(`vm_take_error_value` in `src/vm.c`); an explicitly `throw`n value is bound
unchanged. Only an uncaught error prints the live VM stack. Catching therefore
unwinds the only copy of the original frames before a later throw can use it.

## Runnable evidence: behavior this design changes

The following programs were run against the current checkout's
`build/release/eigenscript`. They are evidence fixtures, not doctests that
claim the future result.

### Bare rethrow

`/tmp/rethrow.eigs`:

```eigenscript
define origin() as:
    items is [1]
    print of items[9]
define boundary() as:
    try:
        origin of null
    catch e:
        throw of e
boundary of null
```

Command: `build/release/eigenscript /tmp/rethrow.eigs`. Current exit status is
1 and stderr is:

```text
{"kind": "index_range", "message": "index 9 out of range (list length 1)", "line": 3, "file": "/tmp/rethrow.eigs"}
     8 |         throw of e
       |               ^
  at boundary (/tmp/rethrow.eigs:8)
  at <module> (/tmp/rethrow.eigs:9)
```

`origin` is gone. Under this design, bare `throw of e` re-raises the same error,
prints one error, and retains `origin` line 3 as its innermost frame.

### Context wrapper

`/tmp/wrap.eigs` differs only in the handler:

```eigenscript
define origin() as:
    items is [1]
    print of items[9]
define boundary() as:
    try:
        origin of null
    catch e:
        throw of {"kind": "service", "message": "request failed", "cause": e}
boundary of null
```

Command: `build/release/eigenscript /tmp/wrap.eigs`. Current exit status is 1
and stderr is:

```text
{"kind": "service", "message": "request failed", "cause": {"kind": "index_range", "message": "index 9 out of range (list length 1)", "line": 3, "file": "/tmp/wrap.eigs"}}
     8 |         throw of {"kind": "service", "message": "request failed", "cause": e}
       |               ^
  at boundary (/tmp/wrap.eigs:8)
  at <module> (/tmp/wrap.eigs:9)
```

Today `cause` is merely printed dictionary data and its origin stack is gone.
The proposal prints the original error and frames first, then `Caused by:` and
the service error with the wrapper's stack. A handler can read `e.cause` and
`e.cause.frames` normally.

## Prior art translated to EigenScript

### Python: traceback, `__context__`, and `__cause__`

[Python's exception model](https://docs.python.org/3/reference/simple_stmts.html#the-raise-statement) uses bare `raise`, which preserves a caught exception's traceback. Raising while
handling another exception supplies implicit `__context__`; `raise X from Y`
selects explicit `__cause__` and affects display. EigenScript needs the useful
split—preserve on `throw of e`, explicitly wrap with `cause: e`—but not implicit
context, suppression state, classes, or new bare-raise syntax. Explicit-only
chaining avoids surprising provenance after a handler intentionally recovers.

### Rust: `Error::source`

[Rust's `Error::source`](https://doc.rust-lang.org/std/error/trait.Error.html#method.source) exposes an optional predecessor independently of display.
The direct equivalent is an optional `cause` member: programs traverse
`e.cause`, then `e.cause.cause`, without parsing text. Ordinary dictionaries
and field access replace a new trait or error interface.

### Go: `%w`

[Go's `%w`](https://pkg.go.dev/fmt#Errorf) constructs an error that `Unwrap` can recover, whereas formatting an
error as text loses its identity. A structured dictionary with `cause: e` is
EigenScript's `%w`; interpolating `e` into `message` is only text and creates no
chain. Wrapping is deliberate and preserves the original structured value.

## Minimal proposed shape

### Where frames live

Keep errors as ordinary dictionaries. At the transition into a matching
handler, before unwinding destroys the stack, a built-in error becomes:

```eigenscript
{
    "kind": "index_range",
    "message": "index 9 out of range (list length 1)",
    "file": "app.eigs",
    "line": 3,
    "frames": [
        {"file": "app.eigs", "line": 3, "function": "origin"},
        {"file": "app.eigs", "line": 6, "function": "boundary"},
        {"file": "app.eigs", "line": 9, "function": "<module>"}
    ]
}
```

`frames` lives on the caught value, not in VM-global or pointer-keyed metadata:
the value can outlive its handler, cross functions, and travel through tasks.
Order is innermost first, matching the human stack and PR #2173's JSON schema.
The top-level location equals the first frame when present. Dictionary/frame
allocation remains lazy and occurs only once an error selects a handler.

User-thrown strings, lists, numbers, and unrelated dictionaries remain
unchanged. A dictionary is provenance-bearing only if the runtime created it
for a built-in error or `throw` validates a wrapper with string `kind`, string
`message`, optional valid `frames`, and optional provenance-bearing `cause`.
Do not infer provenance from a `cause` key alone. Cycles, malformed chains, and
chains beyond a documented finite limit raise a catchable `value` error.

### Rethrow, attach, and read a cause

* `throw of e` for a caught provenance-bearing value reuses `e.frames`. It does
  not stamp the rethrow site over the origin or make `e` its own cause.
* A new structured dictionary with `cause: e` is the minimal explicit wrapping
  operation. `throw` captures the wrapper's current frames and retains `e` by
  normal value ownership. No grammar or new builtin is necessary.
* A later handler reads the predecessor with normal `e.cause` field access.
  Absence means no cause; `has_key of [e, "cause"]` tests safely.

Validation must snapshot inputs before retaining or normalizing them. Traversal
is read-only: it must not lazily mutate a shared dictionary, preserving the
concurrent-read guarantee.

### Human output

For a chain, print the oldest cause first: its kind/message and stored frames,
then one `Caused by:` line and the next outer error. A bare rethrow prints one
error and the original frames. A caught error remains silent. This ordering
makes the initiating fault visible before package-added context.

## Tape and replay consequences

Throws are deterministic control flow, not nondeterministic inputs, so there is
no new tape event. The existing `L` identifies the throwing statement; handler
entry and catch binding use the existing line/scope/assignment model described
in `docs/TRACE.md`. If observed in an `A` record, normal value serialization
includes `frames` and recursively includes `cause` like any dictionary/list;
the existing container-cycle refusal applies.

Record and replay reconstruct frames independently from the same compiled
frame stack. Interpreter, JIT, and OSR must therefore yield byte-identical
values and diagnostics. Names come from chunks—never addresses, clocks, thread
IDs, or scheduling. Task transfer retains/clones the complete structured error;
`task_join` must not rebuild frames at the join site.

Adding `frames` changes an observable catch value, dictionary key enumeration,
and possibly `A` payloads. The implementation must bump the tape format version
rather than accept a pre-provenance tape silently. It needs no additional trace
hook: all work remains on the error path.

## JSON diagnostic field

PR #2173 defines ordinary-run schema version 1 with `version`, `code`, `kind`,
`message`, `file`, `line`, `column`, `span`, and innermost-first `frames`, and
explicitly defers causes. Provenance bumps it to version 2 and adds optional
`cause`, recursively using the runtime diagnostic shape without another
`version` member:

```json
{
  "version": 2,
  "code": "service", "kind": "runtime", "message": "request failed",
  "file": "app.eigs", "line": 8, "column": 15, "span": 1,
  "frames": [{"file":"app.eigs","line":8,"function":"boundary"}],
  "cause": {
    "code": "index_range", "kind": "runtime",
    "message": "index 9 out of range (list length 1)",
    "file": "app.eigs", "line": 3, "column": 0, "span": 0,
    "frames": [{"file":"app.eigs","line":3,"function":"origin"}]
  }
}
```

Omit `cause` rather than writing `null`. Preserved frames have no columns, so
unavailable cause `column`/`span` are zero. JSON is structurally outermost-first
for natural machine access even though human output renders oldest-first. The
emitter uses the same cycle/depth guard as program traversal.

## Zero cost on the non-error path

The implementation must add no field to `Value`, per-call allocation, frame
copy, reference-count operation, branch in ordinary opcode dispatch or
function entry/return, and no tape record for successful execution. Frames are
copied only after an error selects a handler, beside today's lazy catch-value
construction. Cause validation/retention occurs only inside `throw`, already an
error path; uncaught output snapshots only as needed. Thus non-error execution
has **zero additional instructions, allocations, bytes per value, and tape
records**, not merely amortized or predicted-not-taken cost.
