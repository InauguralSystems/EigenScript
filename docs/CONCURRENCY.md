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

## The multithreaded performance cliff

The first `spawn` in a program permanently flips the runtime into
multithreaded mode (`g_vm_multithreaded`). From that point the #297 safety gates
turn **off** the JIT counters, OSR, and inline-cache writes — parallel code runs
interpreter-only, because those single-threaded fast paths are not safe to
mutate concurrently. So concurrency trades peak single-thread throughput for
parallelism: use threads for genuinely parallel work, not to speed up a tight
serial loop. (A quantified before/after number lands with the replay-pinned
benchmark harness, #398.)

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

## The race gate

The claim that the spawn/channel machinery is data-race-free is not a comment —
it is regression-gated. `make tsan` builds a ThreadSanitizer interpreter and
`tests/test_tsan.sh` runs the concurrency test slice under it (`setarch -R`,
since ThreadSanitizer needs ASLR off here). The same gate runs a **deliberately
seeded race** and asserts ThreadSanitizer catches it, so the gate cannot rot
into a vacuous pass. It runs as the `tsan` job in CI.
