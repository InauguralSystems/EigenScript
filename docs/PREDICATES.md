# Predicates

The bare predicate words — `converged`, `equilibrium`, `stable`,
`improving`, `diverging`, `oscillating` — and the `report of x` builtin
classify a value's recent trajectory into one of those bands. This file
is the spec: what each one means precisely, the windowed formula it
evaluates, a canonical `dH`-sequence trace, and the pointwise behavior it
replaces. ([`docs/OBSERVER.md`](OBSERVER.md) is the model; this is the
operational target the runtime enforces.)

These are **trajectory claims, not snapshot claims.** `improving` means
"the value has been getting more determined *over its recent history*",
not "the last single step happened to go down." The canonical use is a
loop condition — `loop while improving`, `loop while not stable` — which
must be robust to a single noisy tick. That is why every predicate reads
a **window** of the last `N` observations rather than the instantaneous
`dH`. (The original observer semantics were trajectory-based; the early C
runtime simplified five of the six to single-step checks, which flickered
under noise — see "Pointwise behavior replaced" in each section.)

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
first push only happens once `obs_age >= 1`), so a value that has never
been read pays no allocation. Arena values skip the buffer entirely —
they cannot be tracked across resets.

`window` below means the `dh_window` contents oldest→newest;
`count = window_size(v)` is how many real samples it holds (≤ N).

## Thresholds

Three numbers from `EigsState` (defaults shown):

```
dh_zero  = 0.001   |dH| below this is "essentially zero change"
dh_small = 0.01    |dH| below this is "small but nonzero change"
h_low    = 0.1     entropy below this is "low information content"
```

Override with `set_observer_thresholds of [dh_zero, dh_small, h_low]`.

Two derived window constants (functions of `N = OBSERVER_WINDOW_N = 10`):

```
VOTE  = 0.6                min fraction of genuine same-direction steps for improving/diverging
FLIPS = ceil(N / 3)  = 4   min sign-flips in the window for oscillating
```

## Partial-window rule (applies to all six)

If the window does not yet hold enough samples, **every predicate returns
`false`** — "we haven't seen enough yet to claim anything." The minimum is
`N` for the full-window predicates (`converged`, `stable`, `equilibrium`)
and `3` for the trajectory predicates (`improving`, `diverging`,
`oscillating`). A two-write program can never report any predicate true;
this is the single most important difference from the old pointwise rule,
which fired on the first step.

## Implementation status

The spec describes the **target** windowed semantics. Shipped state:

| Predicate | Windowed? | Tracked by |
|-----------|-----------|------------|
| `converged` | ✅ shipped (`vm.c` kind 0) | #204 (done) |
| `stable` | ⏳ target | #205 |
| `oscillating` | ⏳ target | #206 |
| `improving` | ✅ shipped (`observer_improving`, `vm.c` kind 2 + report) | #207 (done) |
| `diverging` | ⏳ target | #208 |
| `equilibrium` | ⏳ target | #209 |

Until a predicate's rewrite lands, the runtime evaluates the pointwise
body documented under "Pointwise behavior replaced". `report of x` follows
the predicate implementations and is updated alongside them.

## The six predicates

### `converged` (kind 0)

```
count == N
  AND for every dH in window: |dH| < dh_zero
  AND entropy < h_low
```

The strongest band: the value is at rest, has *been* at rest for a full
window, and sits in a low-information basin. A trajectory that stops for
one step but is information-rich (e.g. an irrational fixed point) is
`equilibrium`, not `converged` — the `entropy < h_low` clause blocks it.

**Trace** (`dh_zero=0.001`, N=10):

| step | window (newest last) | entropy | converged |
|------|----------------------|---------|-----------|
| 1–9 | filling (count < 10) | — | `false` (partial) |
| 10 | `[0,0,0,0,0,0,0,0,0,0]` | 0.00002 | **`true`** |
| 11 | `[...,0, 0.5]` (one spike) | 0.00002 | `false` (window not all-quiet) |

**Pointwise behavior replaced:** `|dH| < dh_zero && entropy < h_low` —
fired after a single quiet step, a false positive for any iterative
scheme whose first quiet step is followed by more motion (Newton early in
descent, gradient descent crossing a saddle).

### `equilibrium` (kind 5)

```
count == N
  AND |mean(window)| < dh_zero
  AND variance(window) < dh_zero^2
```

The window is centered on zero motion with negligible spread — the value
is sitting still on average, regardless of entropy. `converged` is the
strict subset of `equilibrium` that also requires every individual `dH`
near zero *and* low entropy; a value can be at `equilibrium` (zero-mean,
low-variance) while still information-rich.

**Trace:**

| step | window | mean | var | equilibrium |
|------|--------|------|-----|-------------|
| 10 | `[0,0,…,0]` | 0 | 0 | **`true`** |
| 10 | `[+0.0008,−0.0007,…]` tiny zero-mean | ~0 | < 1e-6 | **`true`** |
| 10 | `[+0.5,−0.5,+0.5,…]` zero-mean, high var | ~0 | 0.25 | `false` (variance) |

**Pointwise behavior replaced:** `|dH| < dh_zero` — a single near-zero
step, with no persistence or spread check.

### `stable` (kind 1)

```
count == N
  AND for every dH in window: |dH| < dh_small
  AND entropy >= h_low
  AND no consecutive sign flips in window
    (no i with window[i]*window[i+1] < 0 and both |.| > dh_zero)
```

Small but nonzero motion at high information content, holding its
direction — the "doing a little, but settled and not bouncing" band.
Excludes the oscillation case so the bands stay mutually exclusive in the
gray region.

**Trace** (`dh_small=0.01`):

| step | window | entropy | stable |
|------|--------|---------|--------|
| 10 | `[0.003,0.004,0.003,…]` small, same sign | 0.4 | **`true`** |
| 10 | `[0.003,−0.004,0.003,−0.004,…]` flipping | 0.4 | `false` (sign flips) |
| 10 | `[0.02,0.03,…]` exceeds dh_small | 0.4 | `false` (too large) |
| 10 | small same-sign | 0.02 | `false` (entropy < h_low) |

**Pointwise behavior replaced:** `|dH| < dh_small && entropy >= h_low &&
!(dH*prev_dH < 0 && |dH| > dh_zero)` — a two-point sign check instead of a
full-window one.

### `improving` (kind 2)

```
count >= 3
  AND sum(window) < 0                      (NET entropy descent — magnitude-aware)
  AND down_fraction >= VOTE                (VOTE = 0.6; a "down" step is dH < -dh_small)
```

where `down_fraction = (# steps with dH < -dh_small) / count`, tested in
integers as `down * 5 >= count * 3`.

Information content is *falling over the window* — the value is becoming
more determined. The rule is a hybrid of two independent guards:

- **`sum(window) < 0`** is the magnitude-aware net test. The window's `dH`
  values telescope to `entropy_now − entropy_oldest`, so `sum < 0` means
  the value ends the window *more* determined than it began. A run that
  ticks down on most steps but ends with *higher* entropy (a few large
  up-ticks outweighing many small descents) is **not** improving.
- **`down_fraction >= 0.6`** is the proportional vote: a sustained majority
  of steps must be *genuine* descents (clearing the gray band at
  `dh_small`). This tolerates noisy up-ticks without an absolute cap, and —
  by using `dh_small`, not `dh_zero` — keeps a steady gray-band descent out
  of `improving`: such a window has `down_fraction = 0` and reads `stable`,
  honoring the #187 mutual-exclusivity contract.

> **Design note.** This is a deliberate hybrid, not a port of an ancestor
> rule. EigenChat's `TemporalLossState.is_improving` is a magnitude-blind
> directional ratio vote (it reports "improving" even on a net-worsening
> run); the legacy *language* predicate was pointwise (`radius decreasing`).
> We take the ratio vote's noise tolerance and add the `sum < 0` magnitude
> gate so a net-worsening trajectory is never called improving.

**Trace** (`dh_small = 0.01`):

| step | window | net sum | down/count | improving |
|------|--------|---------|------------|-----------|
| 3+ | steady descent, all dH < −dh_small | < 0 | 1.0 | **`true`** |
| 3+ | descent with a couple of up-ticks, still 60%+ down | < 0 | ≥ 0.6 | **`true`** |
| 3+ | most steps down but net entropy rose | ≥ 0 | — | `false` (sum ≥ 0) |
| 3+ | net down but < 60% genuine descents | < 0 | < 0.6 | `false` (vote) |
| 3+ | steady gray-band descent (|dH| < dh_small) | < 0 | 0.0 | `false` → `stable` |
| 2 | — | — | — | `false` (count < 3) |

**Pointwise behavior replaced:** `dH < -dh_small` — fired on a single
negative tick and dropped the next frame if entropy bounced; flickered
under noise (#207).

### `diverging` (kind 4)

Mirror of `improving` (target spec for #208):

```
count >= 3
  AND sum(window) > 0                      (NET entropy ascent — magnitude-aware)
  AND up_fraction >= VOTE                  (a "up" step is dH > +dh_small)
```

Information content rising over the window — the value becoming less
determined — with the same magnitude gate and proportional vote, sign
reversed. (EigenChat used an *asymmetric* threshold here — divergence
required stronger evidence, 0.8 vs improving's 0.6, to avoid false alarms
on a temporary setback. The C target keeps `VOTE = 0.6` for symmetry; revisit
if divergence proves trigger-happy in practice.)

**Trace:** symmetric to `improving` with the sign of the net sum and the
vote direction reversed.

**Pointwise behavior replaced:** `dH > dh_small`.

### `oscillating` (kind 3)

```
count >= 3
  AND sign_flip_count(window) >= FLIPS     (FLIPS = ceil(N/3) = 4)
```

The `dH` sign flips at least `FLIPS` times across the window — sustained
back-and-forth, not a single reversal. A `sign_flip` counts adjacent
samples whose product is negative and whose magnitudes both clear
`dh_zero` (sub-noise wobble does not count).

**Trace:**

| step | window dH signs | flips | oscillating |
|------|-----------------|-------|-------------|
| 10 | `+ − + − + − + − + −` | 9 | **`true`** |
| 10 | `+ + + − − − + + +` | 2 | `false` (< 4 flips) |
| 10 | one reversal then steady | 1 | `false` |

**Pointwise behavior replaced:** `dH*prev_dH < 0 && |dH| > dh_zero` — a
single adjacent sign flip, indistinguishable from one reversal in an
otherwise monotone descent.

## Mutual exclusion

Under the windowed semantics the bands are designed to be mutually
exclusive within one observation:

- `converged` ⊂ `equilibrium` (every converged window is zero-mean and
  low-variance; `report` resolves to `converged` when both hold).
- `improving` and `diverging` require opposite net trends, so at most one
  fires.
- `oscillating` requires ≥ `FLIPS` sign changes, which a window with a
  monotone net trend (improving/diverging) cannot have, and the `stable`
  no-consecutive-flips clause excludes it from the small-motion band.
- `stable` requires every `|dH| < dh_small`; `improving`/`diverging`
  require ≥ 60% of steps to *clear* `dh_small` in one direction, so a
  uniformly small-motion (gray-band) window satisfies `stable` and has a
  `down_fraction`/`up_fraction` of 0 — it can never be improving or
  diverging. This is the #187 contract enforced at the window level.

> **Note (pre-rewrite):** while the five non-`converged` predicates are
> still pointwise (see Implementation status), the bare predicates are
> NOT fully mutually exclusive — a large-amplitude sign flip satisfies
> both `oscillating` and `diverging`, and a quiet step at high entropy
> satisfies both `stable` and `equilibrium`. `report of x` disambiguates
> by priority order. `tests/test_predicate_matrix.eigs` pins this current
> behavior; it is updated as each rewrite lands.

## The `report` builtin

`report of x` (builtins.c:`builtin_report`) returns the first matching
band, tested in priority order. The target order under windowed semantics:

1. `oscillating`
2. `diverging`
3. `improving`
4. `converged`
5. `equilibrium`
6. `stable` (fallback)

`report of x` and `if <predicate>:` are kept in lockstep so
`report of x == "converged"` agrees with `if converged:` on the same
value, and likewise as each band is rewritten.

## Canonical examples

### Iterating at a low-entropy value → `converged`

```eigenscript
x is 1000000
for i in range of 12:
    x is 1000000   # same value 12 times → window fills with dH=0
if converged:
    ...   # YES — full quiet window AND low entropy (large magnitude)
```

### Newton's sqrt on an information-rich fixed point → `equilibrium`

`sqrt(2)` settles to `1.41421…` and `dH → 0`, so the window goes quiet and
zero-mean — but `1.41421…` is information-rich (`entropy >= h_low`), so it
reports `equilibrium`, not `converged`. See
`tests/test_windowed_converged.eigs` WC4.

### Short trajectories never fire

```eigenscript
y is 0
y is 0
if converged:
    ...   # NO — count = 2 < N; partial-window rule returns false
```

## Cost

The `dh_window` costs one `xcalloc(N * sizeof(double))` (80 bytes at N=10)
per *interrogated* value, lazily on the second observation. Per assignment
the cost is one buffer write + head advance, gated on the compile-time
observer-tracking flag — values that no predicate or interrogative ever
reads pay nothing. Free is handled in `free_value` before the `VAL_NUM`
freelist path so recycled numbers do not leak the buffer.

## See also

- [`docs/OBSERVER.md`](OBSERVER.md) — the model behind the predicates
- [`docs/SPEC.md`](SPEC.md) — language-level surface (the words as
  expressions and as bare conditions)
- `tests/test_predicate_matrix.eigs` — the predicate-family regression
  matrix (issue #200)
- `tests/test_windowed_converged.eigs` — lock-in tests for windowed
  `converged`
- `tests/test_report_alignment.eigs` — report-predicate agreement
