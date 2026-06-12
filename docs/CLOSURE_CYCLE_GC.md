# Closure-cycle reclamation — design note

Status: **known limitation, not yet fixed.** This note records the
investigation behind that decision so the eventual fix is de-risked.

## The leak

A closure captures its entire defining `Env`; that env, in turn, holds a
reference to the closure (the `define`/lambda binding lives *in* the env
the closure captures). The two keep each other's refcount above zero, so
neither is ever reclaimed:

```
define outer as:
    x is 5
    define inner as:   # inner captures outer's env E (uses x)
        return x
    return inner       # E binds `inner`; `inner`.closure == E  → cycle
f is outer of null
```

It **accumulates** — it is not a one-shot exit-time blip. Measured under
`ASAN_OPTIONS=detect_leaks=1`:

| program | leaked allocations |
|---|---|
| 1 escaping closure | ~12 (the env arrays, the fn, the captured tracked-num, bound strings) |
| 500 closures kept in a list | 5,553 |
| 500 closures created & discarded in a loop | 6,004 |

So any long-running program that builds closures over time grows
without bound. The dispatch-table pattern (`table is [op0, op1, …]`)
is safe **only because** those closures are created once at startup;
build them per-iteration and they leak.

### What does *not* leak (the precise invariant)

The cycle must involve a **captured `Env`**. Empirically:

| shape | leaks? |
|---|---|
| direct closure cycle (`define inner` returned) | yes |
| list/dict of closures returned (`return [h1, h2]`) | yes — still the env↔fn cycle; the container is just another holder of the fn |
| self-referential list (`append of [a, a]`) | no |
| self-referential dict (`d.self is d`) | no |
| mutual recursion that does **not** escape (`return is_even of 4`) | no |

Pure value→value cycles (a list containing itself) are reclaimed by the
existing teardown; only `Env`-involving cycles persist.

## Why the cheap fixes are wrong (each introduces UAF)

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

Both directions are individually load-bearing, so neither edge can be
weakened without escape analysis the runtime doesn't have at that point.

## Why a collector is a real project here (not a patch)

A correct cycle collector needs either per-object incoming-reference
counts (trial deletion / CPython-style) **or** a complete root set
(mark-sweep). This runtime gives neither for free:

- **`Env` has no uniform refcount.** `env_refcount` is incremented in
  exactly one place — `make_fn`, for closures. Child envs reference
  their parent via `Env::parent` with *no* count; active call frames
  reference their env with *no* count. So an env's true incoming-ref
  total = closures (counted) + child envs (uncounted) + live frames
  (uncounted). Trial deletion can't compute an env's external refcount
  locally. Fixing this means reworking env lifetime into a real
  refcount — on the hottest path in the VM (per-call `env_new`/
  `env_free`, the env-recycling freelist, the JIT's `%r12` `fn_env`
  cache).

- **Mark-sweep needs an all-objects registry** to know the universe to
  sweep — intrusive next/prev links added at every `env_new` and every
  value constructor, including the `make_num` freelist fast path. Plus a
  **complete root set** enumerated at a safe point: the whole VM operand
  stack, every active frame's `env` and `fn_env`, `g_last_observer`,
  `g_builtin_call_env`, the trace tape, module-slot-promoted values, the
  env/num freelists, and JIT-parked envs (`chunk->env_cache`). A single
  missed root is a silent use-after-free in *every* program.

Either path is a large change whose failure mode is memory corruption,
not a leak. A subtly-wrong collector is strictly worse than the current
tolerated, tallied leak. So this is scoped as a dedicated, reviewed
effort — not a drive-by patch.

## Recommended approach when it is taken on

1. **Unify `Env` lifetime into a real refcount first**, as its own
   reviewed change: `parent` links and frame usage incref/decref like
   closures do. Validate alone against the full ASan/UBSan suite and the
   JIT (the env-recycling and `%r12` cache paths are the danger).
2. **Then** add localized trial deletion (Bacon–Rajan synchronous
   recycler) rooted at captured envs, triggered when a closure releases
   its env and the env survives. Conservative by construction: free a
   subgraph only when *every* node's external refcount is provably zero;
   when in doubt, do nothing (leak — safe), never free.
3. Restrict collection to `g_vm_multithreaded == 0` initially (spawned
   programs keep the current behavior — their cross-thread roots aren't
   locally visible).
4. Gate on: every shape in `tests/test_closure_cycles.eigs` going
   ASan-clean, the full suite leak tally dropping to 0 (so the gate can
   become hard `detect_leaks=1` with no tolerance), and `make fuzz`.

## Current mitigation

`tests/run_all_tests.sh`'s `rc_ok` tolerates exactly one nonzero-exit
shape — output containing `LeakSanitizer: detected memory leaks` — and
tallies it in the final summary. Crashes, asserts, and UBSan still fail.
`tests/test_closure_cycles.eigs` pins the **functional** correctness of
every cycle shape (the values stay right even though memory isn't
reclaimed) and the clean-case invariants (self-referential containers
and non-escaping recursion must stay leak-clean) so a regression toward
UAF or a wider leak is caught.
