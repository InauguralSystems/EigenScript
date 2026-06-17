# Predicates

The bare predicate words — `converged`, `equilibrium`, `stable`,
`improving`, `diverging`, `oscillating` — and the `report of x`
builtin classify a value's recent trajectory into one of those bands.
This file is the spec: what each one means precisely, what trajectory
it requires, and how it relates to the per-Value observer state
([`docs/OBSERVER.md`](OBSERVER.md) is the model; this is the
operational truth the runtime enforces).

## Inputs

Every predicate reads the same observer state on the most recently
assigned top-level value (`g_last_observer`):

| Field | What it is | Computed by |
|-------|-----------|-------------|
| `entropy` | current information content `where is x` | `compute_entropy_impl` |
| `dH` | change since previous observation `why is x` | `update_observer` (`new − last`) |
| `prev_dH` | the previous step's `dH` | `update_observer` |
| `dh_window` | ring buffer of the last `OBSERVER_WINDOW_N` (=10) `dH` values | `observer_window_push` in `update_observer` |
| `obs_age` | number of observations since the value first existed | `update_observer` |

The ring buffer is allocated lazily on the *second* observation (the
first push only happens once `obs_age >= 1`), so a value that has
never been read pays no allocation. Arena values skip the buffer
entirely — they cannot be tracked across resets.

## Thresholds

Three numbers from `EigsState` (defaults shown):

```
dh_zero  = 0.001   |dH| below this is "essentially zero change"
dh_small = 0.01    |dH| below this is "small but nonzero change"
h_low    = 0.1     entropy below this is "low information content"
```

Override with `set_observer_thresholds of [dh_zero, dh_small, h_low]`.

## The six predicates

Each row gives the exact predicate body from `vm.c:CASE(PREDICATE)`
(line ~3895) and what trajectory it requires. `N = OBSERVER_WINDOW_N`.

### `converged` (kind 0) — windowed

```
window_size(v) >= N
  AND for every i in 0..N: |window[i]| < dh_zero
  AND entropy < h_low
```

**Requires a full window of N near-zero `dH` values** plus low current
entropy. Single-step quiet does not converge — `converged` is a
*trajectory* claim, not a snapshot claim. A value that has been
observed fewer than N times can never report `converged`.

This is the strongest band: the value is at rest *and* has been at
rest long enough to make the rest believable, *and* it is sitting in
a low-information basin (one of `where`'s minima, see
[`OBSERVER.md` § The manifold](OBSERVER.md#the-manifold-two-basins-and-a-horizon)).

### `equilibrium` (kind 5) — pointwise

```
|dH| < dh_zero
```

The current step is near-zero. No window requirement, no entropy
gate. This is what you get when the value just stopped changing but
either (a) hasn't been still long enough for `converged` or (b)
isn't sitting at low entropy. `report of x` returns `equilibrium`
exactly when this fires and `converged` does not.

### `stable` (kind 1) — pointwise

```
|dH| < dh_small
  AND entropy >= h_low
  AND NOT (dH * prev_dH < 0 AND |dH| > dh_zero)
```

Small but nonzero change at high information content, and not
currently sign-flipping. The "small-band probabilistic signal" — the
value is doing something but the runtime treats it as noise. Excludes
the oscillation case so the predicates can be mutually exclusive in
the gray band.

### `improving` (kind 2) — pointwise

```
dH < -dh_small
```

Information content is *falling fast* — the value is becoming more
determined. Switching threshold is `dh_small` (not `dh_zero`), so the
gray band agrees with `stable` and `report`. (Fixed in v0.15.3 — see
CHANGELOG.)

### `diverging` (kind 4) — pointwise

```
dH > dh_small
```

Mirror of `improving`: information rising fast, value becoming less
determined.

### `oscillating` (kind 3) — pointwise

```
dH * prev_dH < 0 AND |dH| > dh_zero
```

Sign of `dH` flipped *and* the magnitude is above the noise floor.
Two-point check, not windowed.

## The `report` builtin

`report of x` (builtins.c:`builtin_report`) tests in this order and
returns the first match:

1. `oscillating` — `prev_dH != 0 && dH * prev_dH < 0 && |dH| > dh_zero`
2. `diverging` — `dH > dh_small`
3. `improving` — `dH < -dh_small`
4. `converged` — same windowed test as `converged` predicate above
5. `equilibrium` — `|dH| < dh_zero`
6. `stable` — `|dH| < dh_small && entropy >= h_low`
7. `stable` — fallback

`report of x` and `if converged:` are deliberately kept in lockstep
for the `converged` case so `report of x == "converged"` agrees with
`if converged:` on the same value. The other report branches are
already pointwise and agree by construction.

## Mutual exclusion

Within one observation, at most one of `{improving, stable,
oscillating, diverging}` fires — the gray-band guard in `stable` and
the `dh_small` switch points for `improving`/`diverging` make them
mutually exclusive. `equilibrium` is the rest-state for the `|dH| <
dh_zero` quiet region; `converged` is a strict subset of
`equilibrium` (every converged value is also equilibrium-quiet, plus
the window and low-H conditions).

## Why `converged` is windowed and the others are not

Pointwise `converged` fires after a single quiet step, which is a
false positive for any iterative scheme whose first quiet step is
followed by more motion: Newton's method early in the descent,
gradient descent crossing a saddle, a simulated annealing trajectory
that just happens to hold its energy for one step. The fix is to
require persistence — the value has to be quiet *and have been quiet*
for `N` consecutive observations. The window length `N = 10` is the
constant `OBSERVER_WINDOW_N` in `eigenscript.h`.

The other predicates are sign-and-magnitude statements about
instantaneous motion (improving/diverging/oscillating) or a quiet
single-step reading (equilibrium/stable) — none of them benefit from
a window the way `converged` does, because they are not asserting
"this state will continue."

## Canonical examples

### Newton's sqrt on a low-entropy fixed point

A trajectory that genuinely settles: `sqrt(2)` reaches `1.41421…` in
~6 iterations and dH drops to 0. But `1.41421…` has high entropy in
the observer's metric (irrational floats are information-rich), so
the value reports `equilibrium`, *not* `converged`. The window is
full and quiet — the `entropy < h_low` clause is what blocks it.
This is correct: the value has stopped moving, but it is not in a
low-information basin. See `tests/test_windowed_converged.eigs` WC4.

### Iterating at a low-entropy value

```eigenscript
x is 1000000
for i in range of 12:
    x is 1000000   # same value 12 times → window fills, dH=0
if converged:
    ...   # YES — full quiet window AND low entropy (repeated value)
```

This is the classic `converged` case, and it requires both
conditions: the window must be full (so a 2-write program can never
converge) and the entropy must be low (so a value sitting at a
distinctive number does not converge even if it stops moving).

### Why short trajectories never converge

```eigenscript
y is 0
y is 0
if converged:
    ...   # NO — only 2 observations, window has count=2 < N=10
```

`window_size < N` short-circuits the predicate to false. The same
value under the old pointwise rule would have fired immediately.
That false positive is exactly what the windowed rewrite is fixing.

## Cost

The dh_window costs one `xcalloc(N * sizeof(double))` (80 bytes at
N=10) per *interrogated* value, lazily on the second observation.
Per assignment the cost is one buffer write + head advance, gated on
the compile-time observer-tracking flag — values that no predicate or
interrogative ever reads pay nothing (the buffer is never allocated).
Free is handled in `free_value` before the VAL_NUM freelist path so
recycled numbers do not leak the buffer.

## See also

- [`docs/OBSERVER.md`](OBSERVER.md) — the model behind the predicates
- [`docs/SPEC.md`](SPEC.md) — language-level surface (the words as
  expressions and as bare conditions)
- `tests/test_windowed_converged.eigs` — the lock-in tests for the
  windowed `converged`
- `tests/test_report_alignment.eigs` — report-predicate agreement
