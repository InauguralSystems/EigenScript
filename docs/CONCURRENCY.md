# Concurrency and the memory model

EigenScript has real OS-thread concurrency: `spawn` runs a closure on a new
thread, `channel`/`send`/`recv` pass messages between threads, and `thread_join`
waits for a worker and returns its result. This document is the contract for
what is shared, what is copied, and what that costs — the questions a static
type cannot answer for you.

## The one rule: VALUES copy, HANDLES share

**A value sent through a channel, or returned through `thread_join`, is COPIED**
(`val_clone_for_send`). Numbers, strings, lists and dicts are share-nothing:
the receiver gets an independent deep copy, so mutating the original after you
send it cannot be observed by the other thread.

**A HANDLE is not a value and does NOT copy** — it points at state the copy
still points at. **Do not read a list of handle kinds out of this prose: read
the table the next section MEASURES.** An earlier revision of this page listed
"three things"; a blind reviewer immediately found a fourth by sending a
channel through a channel. A remembered list goes stale, so the enumeration
here is a program's output. The handle half is open issue
[#1148](https://github.com/InauguralSystems/EigenScript/issues/1148), tracked
by [#1153](https://github.com/InauguralSystems/EigenScript/issues/1153); this
page changes when the fix lands.

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

### Which kinds copy and which share — MEASURED, not remembered (#1148)

`val_clone_for_send` walks the value graph, and a handle's payload is not in
that graph. So the receiver of a handle sees the sender's LATER mutations — the
opposite of the rule above.

The program below sends one value of each kind, mutates the sender's copy
afterwards, and asks the receiver what it sees. **Its output IS the
enumeration**: each row is a verdict the program computed, not a claim anyone
typed, and the suite compares it byte-for-byte. A kind that changes sides moves
this table and fails the build.

```eigenscript
define verdict(pair) as:
    if pair[0] == pair[1]:
        return "copies"
    return "SHARES"

define row(three) as:
    print of (three[0] + (verdict of [three[1], three[2]]))

n is 1
cn is channel of 1
send of [cn, n]
n is 2
row of ["number         ", "1", str of (recv of cn)]

s is "a"
cs is channel of 1
send of [cs, s]
s is "b"
row of ["string         ", "a", recv of cs]

xs is [1, 2, 3]
cl is channel of 1
send of [cl, xs]
set_at of [xs, 0, 999]
row of ["list           ", "[1, 2, 3]", str of (recv of cl)]

d is {"k": 1}
cd is channel of 1
send of [cd, d]
d["k"] is 999
row of ["dict           ", "1", str of ((recv of cd)["k"])]

seen is [1]
define peek(ignored) as:
    return seen[0]
cf is channel of 1
send of [cf, peek]
set_at of [seen, 0, 42]
got_fn is recv of cf
row of ["closure        ", "1", str of (got_fn of null)]

b is buffer of 2
buf_set of [b, 0, 1]
cb is channel of 1
send of [cb, b]
buf_set of [b, 0, 99]
row of ["buffer         ", "1", str of (buf_get of [(recv of cb), 0])]

t is text_builder_new of null
text_builder_append of [t, "a"]
ct is channel of 1
send of [ct, t]
text_builder_append of [t, "B"]
row of ["text_builder   ", "a", text_builder_to_string of (recv of ct)]

inner is channel of 1
cc is channel of 1
send of [cc, inner]
got_chan is recv of cc
send of [inner, 73]
row of ["channel handle ", "empty", str of (recv of got_chan)]
```
```output
number         copies
string         copies
list           copies
dict           copies
closure        SHARES
buffer         SHARES
text_builder   SHARES
channel handle SHARES
```

**The rows the table cannot construct in three lines, and why they behave the
way they do.** `chan_clone_rec` (src/eigenscript.c) switches on `ValType` with
no `default:`, so `-Werror=switch` forces every new type to choose a side; the
switch handles each type explicitly: `VAL_NUM`, `VAL_NULL`, `VAL_STR`, `VAL_LIST`,
`VAL_DICT` are rebuilt (copy), and `VAL_FN`, `VAL_BUILTIN`, `VAL_BUFFER`,
`VAL_TEXT_BUILDER`, `VAL_JSON_RAW` take a refcount (share).
A new `ValType` must choose a side in the switch for the compiler to accept it.
Two kinds are not in the table: `null` and a builtin have no mutable state, so there is nothing to observe. And a **store
handle** and a **thread handle** behave exactly like the channel row: they are
`VAL_NUM` ids into the process handle table (CLAUDE.md, leak tally), so the
NUMBER copies while the resource it names is shared — which is why the channel
row says SHARES even though a number copies.

Until #1148 lands, send an explicit SNAPSHOT rather than the handle:

```eigenscript
c is channel of 1
b is buffer of 4
buf_set of [b, 0, 1.5]
snap is buffer of (buf_len of b)
buf_copy of [b, 0, snap, 0, (buf_len of b)]   # an independent buffer
send of [c, snap]
buf_set of [b, 0, 99]
print of (buf_get of [(recv of c), 0])
```
```output
1.5
```

`text_builder_to_string of t` is the same move for a builder, and a closure
captures its environment by reference whether or not it crosses a channel (the
next section).

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

### A key written by a worker outlives the worker (#1141)

Sharing by reference means the *structure* a worker builds has to survive the
worker, not just its values. It does. **Once a program has `spawn`ed, a dict
KEY written on any thread is valid for the lifetime of the DICT**, whoever
reads it and whether or not the writing thread has exited:

```eigenscript
d is {"pre": 1}
define worker() as:
    d.added_by_worker is 42
    return 0
h is spawn of worker
thread_join of h
print of (keys of d)
print of d.added_by_worker
```
```output
["pre", "added_by_worker"]
42
```

The same holds for a dict the worker builds and publishes through a shared
list, for nested dicts, and for a read that happens long after the worker was
joined and its handle released. (Mechanically: key strings are interned, and
while the process is multithreaded new keys are interned into a
process-global, mutex-guarded table instead of the writing thread's own — the
thread's table is freed when the thread detaches, which is exactly the
lifetime a shared dict does not have.) The guarantee is keyed on the
multithreaded flag that `spawn` sets. The embed API's other thread shape —
host threads attaching to one state without any `spawn` — is NOT covered:
there a detaching host thread still frees the names it interned, dict keys
and global bindings alike (#1162).

This is a statement about the KEY, not about the VALUE. Two threads writing
the same dict, or one writing while another reads, is still **your** race to
avoid: a user data race here is *undefined*, and because the writers touch
allocator-managed structure it can corrupt the heap rather than merely
returning a stale number (#1152). Communicate results; do not share mutable
state between live threads.

## Thread handles: one join per handle (#1146)

`spawn` returns a **handle** — a dict carrying `_handle_id` and `_handle_gen`
— and `thread_join` consumes it. The contract is three rules, each of which
used to be a silent wrong answer or a hang.

**A handle is joined exactly once, by exactly one caller.** `thread_join`
*claims* the handle: under one hold of the handle-table mutex it resolves the
id AND detaches the slot, and only then calls `pthread_join` outside the lock.
So of any number of callers holding the same handle — sequentially, or on two
threads at once — exactly one gets the worker's result and every other one
gets a **catchable** error, `kind` `value`:

```eigenscript
define work(n) as:
    return n * 2
h is spawn of [work, 21]
print of (thread_join of h)
try:
    print of (thread_join of h)
catch e:
    print of f"{e.kind}: {e.message}"
```
```output
42
value: thread_join: thread handle 1 has already been joined
```

Before the claim step, two threads joining one handle both passed the lookup
and both called `pthread_join` on one thread id. That is undefined behaviour
under POSIX, and on glibc the second caller never wakes: the process **hung**,
7/7 runs across two reviewers and 3/3 on the maintainer box, with the loser
then reading the freed handle. A second SEQUENTIAL join returned `null`, which
is also what a worker that returned `null` gives you.

**A handle names a generation, not just a slot.** The table has 255 usable
slots handed out round-robin, so ids recycle. Each slot carries a counter that
is bumped every time the slot is handed out, and the handle carries the value
it was issued at, so a handle held across a full cycle of the table is
**detected** rather than silently aliased to whatever now owns the slot:

```
stale is spawn of [w, "STALE"]
thread_join of stale
... 254 more spawn/join cycles, so the table wraps ...
fresh is spawn of [w, "FRESH"]
thread_join of stale     # raises: stale thread handle (slot N no longer holds it)
thread_join of fresh     # "FRESH"
```

Before the generation, that program joined the STALE handle and got `"FRESH"`,
then joined the FRESH handle and got `null`, at exit status 0. Channel and
store handles carry the same generation (`_channel_gen`, `_store_gen`) and
socket handles pack it into their numeric id. **Cooperative task ids are the
one declared exception** — a task id is a plain number with nowhere to carry a
generation, so `task_join`/`task_alive` resolve by raw slot; a detached task's
slot is recycled, so an id kept past `task_detach` can name a later task
(tracked as #1173). A task that is simply *joined* never releases its slot, on
this version or any earlier one — 255 spawn/join cycles exhaust the table and
raise `task_spawn: too many live tasks` — so `task_detach` is the only way to
reach that ABA at all.

**Which kinds can actually recycle.** Threads and stores release their slot
(`thread_join`, `store_close`), so a real ABA is reachable for both and both
are gated by a live test row. **Channels never release a slot**:
`close_channel` only flips a flag, and the table entry is reclaimed at the exit
drain, so a genuine channel recycle is unreachable from EigenScript today. The
generation is still checked for channels, because the handle VALUE is an
ordinary dict a program can copy, edit or build by hand — a forged or stripped
`_channel_gen` is the reachable shape of the same condition, and that is what
`tests/handles_channel_stale.eigs` presents.

**A refusal says WHICH failure it is, in one vocabulary.** Every kind routes
through one formatter (`handle_raise_unresolved`), so the four answers read the
same whether the handle named a thread, a channel or a store:

| condition | message |
|---|---|
| the slot was released | `thread_join: thread handle 1 has already been joined` · `store_get: store handle 1 has already been closed` |
| the slot holds something else now | `store_get: stale store handle (slot 1 no longer holds the store this handle names)` |
| the slot holds another kind | `recv: handle 1 is not a channel handle` |
| not a handle at all | `send: invalid channel` |

The wording matters because the first three used to be one word. A stale
channel handle was refused with `send: invalid channel` — a refusal, which is
the bar, but indistinguishable from a handle that was never valid, and a user
debugging a recycled handle needs to be told it was recycled.

**Every store builtin refuses a handle it cannot resolve.** `store_get`,
`store_query`, `store_count`, `store_list`-style readers included — not just
the writers. Round 1 added the generation check and `store_get` still turned
the failed resolve into a silent `null`, so the ABA moved from "returns the
wrong record" to "returns nothing", both at exit status 0. Both are the class
this section exists to remove.

**The table is finite and says so.** All handle kinds — threads, channels,
cooperative tasks, sockets, stores — share **255** slots. `spawn`, `channel`,
`task_spawn`, `store_open` and the socket builtins raise a catchable `limit`
error when the table is full; none of them returns `null` for it. Before,
`spawn` printed `Error: handle table full` to stderr — where no program can
see it — and returned `null`, so 300 unjoined spawns reported
`spawned=255 raises=0 silent=45` at exit status 0 and a caller that checked
nothing carried on with 45 workers it had never started.

Gated by `tests/test_handles_mt.sh` (suite [42l]), its rows in
`tests/test_tsan.sh`, and the mutation train in `tools/mutants.sh`
(run `bash tools/mutants.sh handles_mt`).

## Shared envs under MT are named, not inferred (#1161)

The `#607` lock that serializes structural mutation of a shared env asked
`multithreaded && parent == NULL`. Every sealed ROOT env satisfies that; no
imported module's namespace env does, because a namespace is
`env_new(g_global_env)` and has a parent. So the lock never engaged for the
envs that `M.field is v` writes, and two workers adding distinct new fields to
one imported module grew its `names[]`/`slots[]` concurrently — a `realloc`
under a reader. Measured on the pre-fix tree: two workers × 2,000 distinct new
fields crashed the release binary 5/5 (`double free or corruption`,
`realloc(): invalid next size`, SIGSEGV) and reported 61 ThreadSanitizer
findings — 77 of whose stack frames named `env_set_local_hashed` and 64
`dict_set_hashed_raw`, which is why locking only the env would not have been
enough.

The predicate is now a property the env carries (`Env::mt_shared`), set in
exactly two places: a root env at creation, and a module namespace when it is
attached. Every MT-only env guard reads that one predicate, so a new kind of
cross-thread env is one call rather than a second definition of "shared".

A module namespace is **two** structures — the module env, which is the
authority, and the dict mirror that whole-dict readers (`keys of M`, `len of`,
printing, iteration) see. Both are serialized, on the same mutex in separate
holds. That is the runtime's own coupling, not a user data race: the program
wrote one binding assignment and the runtime chose to implement it as two
structures. Two threads writing the same ORDINARY dict is still your race to
avoid, exactly as above.

The read path is unchanged in cost when nothing has spawned: the predicate
still tests the multithreaded flag first, so a single-threaded program pays one
predicted-false branch. Measured, 5,000,000 single-threaded `M.field is v`
writes, n=5 interleaved against f532c8d: 1.1865 s -> 1.1829 s median (-0.3%,
inside the run-to-run spread), `instructions:u` 5.048e9 -> 5.133e9 (+1.7%).

Still yours to avoid: `keys of M` on one thread while another worker is adding
fields is a whole-dict READ against a structural write, and is not serialized.
Join first, or give each worker its own module.

## Loading from workers (#1144)

`import` and `load_file` are ordinary statements, so they are legal inside a
`define` body and therefore inside a spawned worker. **They now work there**,
and this is the contract.

**What the runtime guarantees.** The loader's own machinery is safe under
concurrency:

- The **in-flight load stack** (the `#496` circular-dependency guard) is
  **per thread**. A cycle is re-entrancy on one C stack, so the thread is
  exactly the right scope: two workers loading the *same* module no longer
  accuse each other of a circular dependency, while a real cycle — `a` loads
  `b` loads `a`, on the main thread or inside a worker — is still reported as
  a catchable error. (Before, the stack was per *state*: the release binary
  exited 1 with `load_file: circular dependency — '...' is already being
  loaded` when no cycle existed, and the concurrent `realloc`/`memmove` was a
  use-after-free.)
- The **module cache** is guarded by a per-state mutex, so two workers
  importing at once cannot realloc it under each other, and **exactly one
  instance of a module survives**. Two threads importing the same path can
  both get past the cache probe and both build a private dict and env; the one
  that loses the race to store it then **drops its own instance and adopts the
  winner's**, so every importer — the loser included — reads and writes the
  same module. A write the loser makes *after* its `import` lands in the
  shared instance:

```eigenscript
define writer(n) as:
    import set
    set.shared_marker is 41
    return set.shared_marker
define reader(n) as:
    import set
    local k is 0
    loop while k < 200000:
        k is k + 1
    return set.shared_marker
h1 is spawn of [writer, 1]
h2 is spawn of [reader, 2]
a is thread_join of h1
b is thread_join of h2
import set
print of f"writer={a} reader={b} main={set.shared_marker}"
```
```output
writer=41 reader=41 main=41
```

  This example is checked byte-for-byte by the doc-examples gate; the suite
  row that *forces* the race (a module slow enough that both workers are
  inside the same import at once) is `loader_mt_same_import` in
  `tests/test_loader_mt.sh`. Before that fix the reader never saw the
  writer's value — six runs printed `writer=41 reader=7` with `main` split
  between 7 and 41 — because the loser kept its private instance.

  **What is NOT deduplicated is the module's top-level BODY.** Both threads
  are already executing it when the race is decided, so a module's top level
  can run more than once and its side effects repeat — a `print` at module
  scope printed twice in 2 of 3 runs of a two-worker import. Only the
  resulting bindings are single. Put side effects in a function the importer
  calls, not at module top level, if a worker may import concurrently.
- The **module-namespace table** — the process-global side table behind every
  `M.field` read — is published as an immutable-shape snapshot through one
  atomic pointer, entries are made visible with a release store, removals are
  tombstones rather than a rehash, and a replaced table is retired rather than
  freed while the process is multithreaded. The **read path takes no lock in
  either mode**; only attach/detach serialize. A module another thread is
  attaching *right now* may not be visible for that instant, in which case the
  read falls back to the namespace dict's own entry — the same answer an
  un-projected read gives.
- A **binding name** created by a worker's module-level code is re-homed into
  the process-global intern table at insertion, so it stays valid for the life
  of the env rather than dying with the worker's thread (the #1141 rule,
  applied to the loader's write path).

**What is still yours to avoid.** Loading publishes bindings into a *shared*
scope: `load_file` runs in the loader's scope, and at worker top level that is
the process-wide module env. So **two threads loading the same module are two
threads writing the same bindings**, which is the ordinary shared-mutable-state
race this document opens with — the runtime keeps its own tables consistent,
but the binding's *value*, its refcount and its observer slot are yours. Under
ThreadSanitizer that shape reports on the slot value, not on the loader.
The safe patterns:

- load or import once on the main thread **before** `spawn`, then read from
  the workers; or
- give each worker a **distinct** module to load.

A `spawn`ed worker that imports stdlib modules its siblings do not import is
fine, and is gated (`tests/test_loader_mt.sh`, plus the loader rows in
`tests/test_tsan.sh`).

**Two threads writing one binding is a separate, tracked defect, not just a
style rule.** Because a shared-root slot is read by BORROWING the value and
taking the reference afterwards, a concurrent overwrite can free what the
other thread is still running: two workers that `load_file` a module whose
`define` rebinds one global report ~20 ThreadSanitizer races per run and dump
core roughly 1 run in 5. That is the class the `#607` comment in
`src/eigenscript.c` declares out of scope ("two threads racing on the SAME
slot's value or assign-count"); it predates the loader work and is filed on
its own as #1171 with a repro and a fix direction (a counted reference taken inside the
hold). Until it is closed, treat the two patterns above as a requirement
rather than advice.

**One shared slot the patterns above do NOT avoid: `__loop_iterations__`.**
The runtime publishes a loop's iteration count as an ordinary binding in the
loop's env (`loop_iter_store`, `src/vm.c`). For a MODULE-LEVEL loop that env
is the shared root env — so main's module-level loop and a worker's
module-level loop inside `load_file` write the same slot even when the two
threads load completely different modules. Today the consequence is a lost
update on a runtime-internal counter (the slot holds an immediate number, so
nothing is freed twice and no value your program reads is corrupted); a
`report`/`when is` on that name can under-count. It is tracked with the same
issue.

## Observer arming sets are process-global and locked (#1145)

The observer's two compile-time **arming sets** — the per-name history tier
(`prev of x`, `<kw> is x at L`) and the per-name occurrence tier
(`<kw> is x when <n>`) — record compile-time facts about the whole process, so
they are process-global. Every read and every write of them is taken under one
leaf mutex, **unconditionally**.

Unconditionally, because the two shapes that break them need different
predicates and one of them has no flag to read at all:

- **One state, `spawn`.** A worker compiling `what is q when 1` (through
  `eval`, `load_file` or `import`) grows the occurrence set while other
  workers' assignments walk it. `spawn` widens only the *history* tier to a
  wildcard (#827); the occurrence tier deliberately has none (#868 — a
  wildcard there would put a bounded ring on every name), so no spawn-time
  escape can cover it.
- **Two embed states, no `spawn`.** `multithreaded` is a *per-state* flag, so
  it is 0 on both threads and nothing widens anything. This is the shape
  `src/ext_http.c` runs (a fresh `EigsState` per connection, on its own
  thread), and the shape `tests/test_arming_two_states.c` gates.

Both shapes are covered. The cost is nil on any hot path: an assignment
consults an arming set once per name per *arming generation*, not once per
assignment, and the writers run at compile time.

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
tape. Under `EIGS_REPLAY` the receive family (`recv`, `try_recv`,
`recv_timeout`) **raises a catchable error** rather than diverge silently,
the same fail-loud contract the other non-replayable builtins use (see
docs/TRACE.md, "Non-Replayable Builtins"). Until per-thread N streams exist
(#1142), **any nondeterministic builtin on a non-main thread** raises the
same error — a worker calling `random` used to tear the replay reader
(heap-use-after-free) or silently mix taped and live values. `spawn` and
`thread_join` themselves are not blocked: a worker that returns a **pure**
value (no nondet builtin, no `recv`) still replays deterministically (the
joined result is copied). Keep replayable programs off `recv`, off nondet
builtins inside workers, and off any worker whose result depends on thread
ordering.

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
