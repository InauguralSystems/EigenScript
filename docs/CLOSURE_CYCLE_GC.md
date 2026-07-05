# Closure-cycle reclamation

Status: **implemented.** The env↔fn cycle is reclaimed by a cycle
collector built on honest `Env` refcounts. This note records the
original investigation (kept below — it explains *why* the design looks
the way it does), the as-built design, and the invariants maintainers
must preserve.

## The leak (historical)

A closure captures its entire defining `Env`; that env, in turn, holds a
reference to the closure (the `define`/lambda binding lives *in* the env
the closure captures). The two kept each other's refcount above zero, so
neither was ever reclaimed:

```
define outer as:
    x is 5
    define inner as:   # inner captures outer's env E (uses x)
        return x
    return inner       # E binds `inner`; `inner`.closure == E  → cycle
f is outer of null
```

It **accumulated** — measured before the collector under
`ASAN_OPTIONS=detect_leaks=1`:

| program | leaked allocations (before) | now |
|---|---|---|
| 1 escaping closure | ~12 | 0 |
| 500 closures kept in a list | 5,553 | 0 |
| 500 closures created & discarded in a loop | 6,004 | 0 (collected mid-run) |

Beyond the leak itself, the unbounded growth cost time: a 100k-iteration
closure-churn loop ran ~40% faster after the collector (0.075s vs 0.12s)
with peak RSS dropping from ~124 MB to ~4 MB.

## Why the cheap fixes were wrong (still true)

The cycle is two owning edges: `E → fn` (the binding) and `fn → E` (the
closure's `env_refcount`). Breaking *either* edge unconditionally is
unsafe:

- **Weak self-binding** (make `E`'s binding to its own capturing fn
  non-owning): UAF in the **non-escaping** case. When the binding is the
  *only* reference to the fn (e.g. internal mutual recursion that never
  escapes), weakening it frees the fn while it is still bound and
  callable — the next recursive lookup dereferences freed memory.
- **Weaken the `fn → E` edge** (a self-bound fn doesn't hold
  `env_refcount`): UAF in the **escaping** case. A returned closure
  outlives its frame; with the edge weakened, `E` is freed while the
  live, returned fn still points into it.

Both directions are individually load-bearing, so the fix had to be a
real collector, not an edge-weakening patch.

## The as-built design

Two stages, exactly as the original investigation recommended.

### Stage 1 — honest `Env` refcounts

`env_refcount` is a true owner count. The owners:

1. **Creator** — the call frame (`owns_env`) or the C caller
   (`thread_entry`, `call_eigs_fn`, the `dispatch` builtin, ext_http
   handlers, `OP_IMPORT`'s module env). `env_new` returns with
   refcount 1; the creator's release is `env_decref`.
2. **Closures** — `make_fn` increfs; `free_value(VAL_FN)` decrefs.
3. **Child envs** — `Env::parent` is an owned edge: `env_new` increfs
   the parent, the destructor decrefs it. Loop envs
   (`OP_LOOP_ENV_FRESH`/`END`) move the frame's ref explicitly: FRESH
   transfers the frame's ref into the child's parent edge (and flips
   `owns_env` to 1 for borrowed base-frame envs); END re-takes a frame
   ref on the parent before releasing the child.
4. **Parked recycled call envs** — `chunk->env_cache` holds the single
   ref (transferred from the returning frame; `vm_park_call_env`
   requires `env_refcount == 1` exactly). The parked env keeps its owned
   parent ref, so the take-side `parent == closure` compare can never
   see a recycled pointer.

`env_free`'s conditional, captured-gated semantics are gone; every
release site is a plain `env_decref`. `env_destroy_final` remains only
as a force-destroy escape hatch (no current callers in main).

### Stage 2 — the collector (`gc_collect_cycles`, eigenscript.c)

- **Registry.** `OP_CLOSURE` calls `env_mark_captured`, which links the
  env into a per-state intrusive list (`gc_next`/`gc_prev`/
  `in_gc_list` on `Env`), lock-guarded by `state->gc_lock` while
  multithreaded. `g_global_env` is never registered. The env
  destructor and `env_destroy_final` unlink.
- **Trigger.** Registration is the only way the candidate universe
  grows, so the threshold check lives there — zero cost on the
  dispatch/call hot paths. Threshold: collect when the registry reaches
  `max(64, 2 × live-after-last-collect)`. One more collection runs at
  exit (below).
- **Universe.** Everything reachable from registered envs over **owned
  edges only**: env value slots, `env->parent`, `fn->closure`,
  `fn->chunk` (the OP_CLOSURE ref), `chunk->functions[]`,
  `chunk->env_cache`, list items, dict values. Three node kinds: values
  (LIST/DICT/FN — everything else is a leaf), envs, chunks. Chunks are
  on real cycles: `fn → chunk → env_cache → parent → E → fn` is exactly
  the shape a recycled call env creates. `g_global_env` is a stop node —
  it is permanently rooted by its creator ref, and traversing into it
  would drag the entire heap into every collection.
- **Roots without root enumeration.** For each node, count the
  references arriving from inside the universe. Any node whose refcount
  exceeds that count has an external holder — a VM stack slot, a frame's
  env ref, a C caller's ref, the trace tape, a route table — *every one
  of which is itself a counted ref*, so no VM-state walking is needed
  and a "missed root" is impossible by construction. If accounting ever
  finds more internal references than refcount (an uncounted edge got
  traversed — a bug), the whole collection aborts: the failure mode is a
  leak, never a free.
- **Sweep.** Mark from roots; unmarked nodes are cyclic garbage. Pin
  them (+1 each), clear their outgoing edges with ordinary decrefs, then
  unpin — each node frees through its normal destructor
  (`free_value`/`env_decref`/`chunk_decref`), so observer-alias
  clearing (`g_last_observer`) and freelist recycling behave as usual.
- **Local value cycles (#307).** A self-/mutually-referential list or
  dict built inside a function and dropped touches neither the captured-env
  registry nor the global snapshot, so before #307 it leaked for the life of
  the process. A Bacon-Rajan "possible root" hook closes this: when
  `val_decref`/`slot_decref` drops a LIST/DICT ref *without* reaching zero
  (the object might now be the root of a garbage cycle), `gc_note_possible_root`
  parks it — with one pinning ref and a `gc_buffered` flag (dedup) — on the
  per-state value-candidate buffer (`gc_val_buf`). `gc_collect_cycles` feeds
  that buffer in as pinned seeds alongside the env registry, so the same
  mark-sweep + edge-accounting decides garbage (root iff
  `rc > internal + pinned`); afterward it clears the flags and drops the pins
  (the final pin drop frees the now-edge-cleared garbage; live candidates keep
  their other refs). The buffer drains on the env-registry threshold trigger,
  on its own `GC_VAL_THRESHOLD` trigger, and at exit. The hook is off when
  GC-disabled, mid-collection, or multithreaded, so the hot decref stays
  lock-free and single-threaded-only. (This is *not* identical to
  `env_mark_captured`, whose registration continues under `gc_lock` while
  multithreaded — only its collection trigger is suppressed there.)
- **Exit.** `gc_collect_at_exit(global)` (main.c, both REPL and script
  paths): flush the value-candidate buffer first (`gc_collect_cycles`), then
  snapshot the global scope's container values with one pinning ref apiece,
  `env_clear(global)`, collect with the pins accounted
  (root iff `rc > internal + pinned`), release the pins, then
  `env_decref(global)` drops the creator ref. The snapshot is what
  reclaims pure value→value cycles bound at global scope (a list
  appended to itself) that are unreachable from the captured-env
  registry.
- **Threads.** While `g_vm_multithreaded` is set, mid-run collection is
  deferred but env registration continues under `state->gc_lock` (the
  candidate registry is per-state). The value-candidate hook
  (`gc_note_possible_root`) is off during the MT window, so worker-local
  pure-value cycles are not buffered (see "What still leaks" below), but
  env↔closure cycles captured on workers are registered and reclaimed by
  the exit sweep once the workers are joined (#297). Cross-thread
  refcounts stay correct (atomic).

### Maintainer invariants (violations are UAF or silent leaks)

- **Every owning edge into an `Env` must go through
  `env_incref`/`env_decref`.** A new uncounted holder (a global Env
  pointer that outlives its creator, a cache that stashes an env) breaks
  the root derivation in the *free* direction. If you must hold an env,
  take a ref.
- **`GC_FOR_EACH_CHILD` and `gc_clear_node` move in lockstep** with the
  runtime's ownership model. A new owning edge out of Value/Env/Chunk
  (a new container type, a new chunk field that holds values or envs)
  must be added to both — or deliberately left untraversed, which is
  safe (the target counts as externally rooted and leaks) but should be
  a recorded decision.
- **Only traverse counted edges.** Adding a borrowed/uncounted pointer
  to the walker makes `internal > rc` possible; the sanity abort
  catches it at runtime, but that means collection silently stops
  working.
- **The frame's env ref follows `frame->env`.** LOOP_ENV_FRESH/END are
  a ref *move*, not a leak-fix opportunity; returning mid-loop relies on
  the child's parent chain cascading the release up to `fn_env`.
- **The value-candidate buffer holds a counted pin per entry** (#307).
  `gc_note_possible_root` does `refcount++` and sets `gc_buffered`;
  `gc_collect_cycles` is the *only* place that releases (clears the flag, then
  decrefs). So a buffered LIST/DICT cannot reach refcount 0 outside a
  collection — keep it that way: any new buffer drain must clear `gc_buffered`
  *before* the decref, and must re-arm `g_in_gc` across the drain so the
  freeing child-decrefs don't re-register and realloc the array mid-walk.
- `tests/test_closure_cycles.eigs` (section [87]) and
  `tests/test_value_cycles.eigs` (section [106]) are both gated **strictly** by
  run_all_tests.sh: any LeakSanitizer exit there fails the suite (rc_ok's leak
  tolerance does not apply). [87] guards closure cycles; [106] guards local
  value cycles. Keep it that way.

## What still leaks (known, tolerated)

- **Worker-thread-local pure-value cycles** — the `gc_note_possible_root`
  hook is gated off while multithreaded (to keep the hot decref lock-free), so
  a self-referential list/dict built *and* dropped inside a spawned worker is
  never buffered and isn't reclaimed. (Env↔closure cycles created on workers
  *are* collected — the env registry registers under `gc_lock` during the MT
  window and the exit sweep reclaims them once workers are joined, #297.)
  Worker-local value cycles are rare; out of scope until a consumer needs them.
- A **parked recycled call env pins its parent** (the callee's closure
  env) until the chunk dies or the cycle through the chunk is collected
  — at most one retained env per chunk, released at chunk death.

The suite's tolerated-leak tally (the `NOTE:` line in run_all_tests.sh) is now
**0** — the collector reclaims closure cycles (env-registry), global-rooted
value cycles (exit snapshot), local value cycles (#307 possible-root buffer),
and worker-created closure cycles (#297 per-state registry). It started at 28
before the collector landed.
