# Concurrency and the memory model

EigenScript has real OS-thread concurrency: `spawn` runs a closure on a new
thread, `channel`/`send`/`recv` pass messages between threads, and `thread_join`
waits for a worker and returns its result. This document is the contract for
what is shared, what is copied, and what that costs — the questions a static
type cannot answer for you.

## The one rule: messages copy, closures share

**A value sent through a channel, or returned through `thread_join`, is COPIED**
(`val_clone_for_send`). Messages are share-nothing: the receiver gets an
independent deep copy, so mutating the original after you send it cannot be
observed by the other thread.

```eigenscript
c is channel of 1
original is [1, 2, 3]
send of [c, original]
set_at of [original, 0, 999]   # mutate the original AFTER sending
received is recv of c
print of received              # the copy — unaffected by the mutation
print of original
```
```output
[1, 2, 3]
[999, 2, 3]
```

A joined result is a copy the same way — a worker that returns a pure value
hands the parent an independent value:

```eigenscript
define square(n) as:
    return n * n
h is spawn of [square, 7]
print of (thread_join of h)
```
```output
49
```

**A spawned closure, by contrast, SHARES the parent heap by reference.** A list
or dict the closure captured is the *same object* the parent still holds. Two
threads mutating it concurrently is a data race — and the race is yours to
avoid, exactly as in C. The safe pattern is to *communicate* results (return
them, or `send` them through a channel) rather than to mutate shared state. The
unsafe pattern — unsynchronized read-modify-write on a shared list from two
workers — is caught by the ThreadSanitizer gate below
(`tests/tsan_seeded_race.eigs`).

## Cooperative tasks are per-thread

`task_spawn`/`task_yield` (#408) are a *different* model from `spawn`:
one OS thread, round-robin, deterministic by construction. The two
compose, and the scoping is what makes that safe — the scheduler, its
ready queue, and the suspend request that drives it all live on
`EigsThread`. A `task_yield` hands control to the next task **on the
calling thread only**; a `spawn`ed worker with no tasks of its own is
never suspended by someone else's yield.

That last part was a bug until #739: the suspend request was a plain
global polled by every `vm_run` at `CASE(CALL)`, so one thread's
`task_yield` sent an unrelated worker into the suspend path. Having no
scheduler, the victim saved no slice and its `vm_run` returned `null`
mid-evaluation — a worker silently produced `null` instead of its
result. `tests/test_tasks.eigs` now runs both models at once.

## The multithreaded performance cliff

The first `spawn` in a program permanently flips the runtime into
multithreaded mode (`g_vm_multithreaded`). From that point the #297 safety gates
turn **off** the JIT counters, OSR, and inline-cache writes — parallel code runs
interpreter-only, because those single-threaded fast paths are not safe to
mutate concurrently. So concurrency trades peak single-thread throughput for
parallelism: use threads for genuinely parallel work, not to speed up a tight
serial loop. (A quantified before/after number lands with the replay-pinned
benchmark harness, #398.)

## The scheduler trace is a reader, not a source (#846)

A schedule visualizer or a DST wants "who ran when" without instrumenting
every yield site. `task_sched_trace of 1` (or `EIGS_TASK_TRACE=1`) arms a
per-thread trace of the cooperative scheduler: one `{seq, tick, task, cause}`
entry per task **resume**, read back with `task_sched_trace of null`. The
cause vocabulary is enumerated from the scheduler's enqueue sites, so every
value names a mechanism: `spawn`, `yield`, `sleep-wake`, `join-release`,
`kill-release`, `recv-wake`, `deadlock` (the #509 re-enqueue of main).

Two properties are load-bearing and gated by `tests/test_task_sched_trace.sh`:

- **Pure reader.** The cause of each ready-queue entry is stamped at enqueue
  time whether or not the trace is armed (one byte, moved in lockstep with the
  queue), and arming only decides whether a pop is written down — after the
  pick, never before it. So the seeded PRNG draws, the clock and the queue
  order are untouched: a run with the trace armed is byte-identical (stdout,
  stderr, exit code) to the same seed with it off.
- **Derived, not taped.** The interleaving is a pure function of program
  order and the seed, so the trace is re-derived on replay rather than
  recorded: it adds no `N` records to the tape, and a tape recorded with the
  trace armed replays to the identical history. A taped copy would be a
  second source of truth that could disagree with the first.

Arming never creates a scheduler (the flag lives on the thread, the history on
the scheduler and is freed with it); the main task's initial run precedes the
first entry and is implicit. The history is unbounded while armed — disarm
(`task_sched_trace of 0`) to discard it.

## Replay boundary (#148)

Thread scheduling is nondeterministic, so it cannot be recorded onto the trace
tape. The unrecordable part is a cross-thread **channel receive** — its arrival
order is not on the tape — so under `EIGS_REPLAY` the receive family
(`recv`, `try_recv`, `recv_timeout`) **raises a catchable error** rather than
diverge silently, the same fail-loud contract the other non-replayable builtins
use (see docs/TRACE.md, "Non-Replayable Builtins"). `spawn` and `thread_join`
themselves are not blocked under replay: a worker that returns a pure value
replays deterministically (the joined result is copied). Keep replayable
programs off `recv` and off any worker whose result depends on thread ordering.

The refusal is a clean exit, never a signal, on the main thread and on a
worker alike: `spawn of [recv, ch]` under `EIGS_REPLAY` prints the diagnostic
and the process exits 1 (#1112 — it died by SIGSEGV before, because a worker
that runs a builtin directly has no VM and the uncaught-error printer read
it). The general rule behind that status: a `spawn`ed worker that dies of an
uncaught error fails the run, joined or not, exactly as a cooperative task
does (#493); an error caught inside the worker, or a worker's `exit of N`,
decides its own status.

## The race gate

The claim that the spawn/channel machinery is data-race-free is not a comment —
it is regression-gated. `make tsan` builds a ThreadSanitizer interpreter and
`tests/test_tsan.sh` runs the concurrency test slice under it (`setarch -R`,
since ThreadSanitizer needs ASLR off here). The same gate runs a **deliberately
seeded race** and asserts ThreadSanitizer catches it, so the gate cannot rot
into a vacuous pass. It runs as the `tsan` job in CI.
