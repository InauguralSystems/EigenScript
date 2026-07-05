# Predicates

The bare predicate words — `converged`, `equilibrium`, `stable`,
`improving`, `diverging`, `oscillating` — and the `report of x` builtin
classify a value's recent trajectory into one of those bands. Each
predicate also has a **named form**, `converged of x` (and so on), that
binds to a specific value rather than the last-observed one — the
preferred form, especially in a loop condition (see
[Convergence loops in practice](#convergence-loops-in-practice)). This file
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
first push only happens once `obs_age >= 1`), so a binding that is never
interrogated anywhere in the program pays no allocation. Arena values skip the buffer entirely —
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

All six predicates are now windowed (the #202 series is complete):

| Predicate | Windowed? | Tracked by |
|-----------|-----------|------------|
| `converged` | ✅ shipped (`vm.c` kind 0) | #204 (done) |
| `stable` | ✅ shipped (`observer_stable`, `vm.c` kind 1 + report) | #205 (done) |
| `oscillating` | ✅ shipped (`observer_oscillating`, `vm.c` kind 3 + report) | #206 (done) |
| `improving` | ✅ shipped (`observer_improving`, `vm.c` kind 2 + report) | #207 (done) |
| `diverging` | ✅ shipped (`observer_diverging`, `vm.c` kind 4 + report) | #208 (done) |
| `equilibrium` | ✅ shipped (`observer_equilibrium`, `vm.c` kind 5 + report) | #209 (done) |

`report of x` follows the same windowed helpers (see The `report` builtin).
The "Pointwise behavior replaced" note under each predicate records the
single-step rule that the windowed version superseded.

All six predicates above (and `report`) classify the trajectory of
**`entropy(value)`**. `report_value of x` (#294) is a sibling that runs the
same windowed logic on the **value's own** relative step `Δv/(1+|x|)` instead
of its entropy — answering "has the number stopped moving" rather than "how
determined is it." It is the right tool when the value oscillates in a
flat-entropy region (where the entropy signal reads `stable`); see
[`docs/OBSERVER.md`](OBSERVER.md) ("Two signals"). Vocabulary:
`oscillating`/`converged`/`stable`/`moving`/`equilibrium`.

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

Mirror of `improving`:

```
count >= 3
  AND sum(window) > 0                      (NET entropy ascent — magnitude-aware)
  AND up_fraction >= VOTE                  (a "up" step is dH > +dh_small)
```

Information content rising over the window — the value becoming less
determined — with the same magnitude gate and proportional vote, sign
reversed. (EigenChat used an *asymmetric* threshold here — divergence
required stronger evidence, 0.8 vs improving's 0.6, to avoid false alarms
on a temporary setback. The C implementation keeps `VOTE = 0.6` for symmetry;
revisit if divergence proves trigger-happy in practice.)

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

Under the windowed semantics the "active motion" bands —
`improving`, `diverging`, `oscillating` — are mutually exclusive, and each
is exclusive of the "at rest" bands. The three quiescent bands form an
intentional subset lattice rather than disjoint sets; `report` resolves to
the most specific via its priority order.

- `improving` and `diverging` require opposite net trends, so at most one
  fires.
- `oscillating` requires ≥ `FLIPS` sign changes, which a window with a
  monotone net trend (improving/diverging) cannot have.
- `stable` requires every `|dH| < dh_small`; `improving`/`diverging`
  require ≥ 60% of steps to *clear* `dh_small` in one direction, so a
  uniformly small-motion (gray-band) window is `stable` with a
  `down_fraction`/`up_fraction` of 0 — never improving or diverging. This
  is the #187 contract enforced at the window level. The `stable`
  no-consecutive-flips clause likewise excludes `oscillating`.
- **The quiescent lattice** (full-window, near-zero motion):
  `converged ⊂ equilibrium`, and a *high-entropy* `equilibrium ⊂ stable`.
  Concretely a full quiet window is exactly one of:
  - **low entropy** → `converged` (and `equilibrium`; `report` →
    `converged`);
  - **high entropy** → `equilibrium` *and* `stable` (`report` →
    `equilibrium`).
  So `equilibrium` never fires alone — it is always accompanied by
  `converged` (low H) or `stable` (high H). A `stable` window that is *not*
  equilibrium is one with steady directional drift (mean `|dH| > dh_zero`):
  moving a little, but settled.

This makes `report`'s priority order load-bearing: `oscillating` →
`diverging` → `improving` → `converged` → `equilibrium` → `stable` returns
the most specific true band. `tests/test_predicate_matrix.eigs` pins the
overlaps and the report resolution.

## The `report` builtin

`report of x` (builtins.c:`builtin_report`) returns the first matching
band, tested in priority order:

1. `oscillating`
2. `diverging`
3. `improving`
4. `converged`
5. `equilibrium`
6. `stable`

These all use the same windowed helpers as the predicates, so
`report of x == "converged"` agrees with `if converged:` on the same value
— **at a full window**. For a *partial* window (`count < N`), the
full-window predicates (`converged`/`equilibrium`/`stable`) are all false
by the partial-window rule, but `report` still needs to say something, so
it falls back to an instantaneous best-effort label: `equilibrium` if the
last `|dH| < dh_zero`, else `stable` if `|dH| < dh_small` at high entropy,
else `stable`. This is the one place `report` can disagree with the bare
predicates, and only while observations are still accumulating — by the
time the window fills, the windowed helpers decide and the two agree.

## Canonical examples

### Iterating at a low-entropy value → `converged`

```eigenscript
x is 1000000
for i in range of 12:
    x is 1000000   # same value 12 times → window fills with dH=0
if converged:
    print of "converged"   # YES — full quiet window AND low entropy (large magnitude)
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
    print of "converged"   # NO — count = 2 < N; partial-window rule returns false
```

## Convergence loops in practice

### A bare predicate reads the *last-observed* binding — name the subject

A bare predicate (`converged`, `stable`, …) has no syntactic subject, so it
classifies whichever binding was **observed last** in scope. Every
assignment is observed, so a trailing assignment silently repoints it:

```eigenscript
loop while not converged:
    x is x * rate     # the quantity you mean
    k is k + 1        # observed last → the bare predicate now reads k
```

`k` increments steadily, its entropy flattens at a fixed step count
regardless of `rate`, and the loop halts on `k` — not `x`. (This is exactly
how `dynamics`' `settle_steps` returned the same count for every rate.)

Name the subject with the **named form**:

```eigenscript
loop while not (converged of x):   # binds to x's slot, every iteration
    x is x * rate
    k is k + 1
```

`converged of x` classifies *x*'s own slot trajectory regardless of what
else is assigned, and a named-predicate loop condition is
self-terminating — it does not arm the global-alias auto-stall that the
bare `loop while not converged` opts into. The same applies as a plain
expression: `report of x` and `converged of x` read *x*; the bare
`converged` reads the last-observed binding. Prefer the named form whenever
more than one binding is observed in scope.

### Gentle, monotonic convergence

`loop while not converged` reads as the obvious convergence idiom, and it
is correct — but only for a value that converges *gently and
monotonically*. Three properties of the entropy model surprise real solvers
(all surfaced building `dynamics`, the observer-heavy dynamical-systems lab
that is the first heavy consumer of the windowed predicates; findings
F-DYN-2 and F-DYN-6). Every trace below is a real run.

### Regime tracks per-step `dH`, not distance to the limit

A predicate classifies the *trajectory* by `|dH|` against `dh_zero` /
`dh_small`. A quantity that is still moving but observed in tiny per-step
increments has `|dH| < dh_zero` and reads settled — `equilibrium` or even
`converged` — while still far from its limit:

```eigenscript
x is 100.0
for i in range of 20:
    x is x * 0.999        # genuine motion, but each step is tiny
report of x               # "converged"  — yet x is still ~98, not ~0
```

The lesson is about **observation cadence**: observe at a rate matched to
the dynamics, not once per micro-step. The robust pattern is to advance the
system several substeps *unobserved* and observe the quantity once per
frame, so each observed `dH` reflects a meaningful step (`dynamics/physics.eigs`
runs `SUB` integration substeps `unobserved`, then observes once per frame
— without this, a damped oscillator, a diverging one, and a steady
oscillation all read `equilibrium` alike).

### Entropy peaks at `|value| = 1`, so a shrinking value can read `diverging`

Entropy is the binary entropy of `p = 1/(1+|x|)`
(`compute_entropy_impl`, eigenscript.c): it is **highest near `|x| = 1`**
and falls toward 0 as `|x| → 0` or `|x| → ∞` (and is defined as exactly `0`
at `|x| ∈ {0, 1}`). So a value decaying from a large magnitude *toward* 1
has **rising** entropy — `dH > 0` — and reads `diverging`, not `improving`,
even though it is "getting smaller":

```eigenscript
x is 100.0
for i in range of 13:
    x is x * 0.7          # 100 → ~1: entropy climbs 0.10 → ~1.0
report of x               # "diverging"  (rising information content)
```

Do not equate "value decreasing" with `improving`/`converging`. The
observer measures information content, not magnitude; "more determined"
means lower entropy, which for `|x| > 1` means moving *away* from 1.

### A fast residual settles at `equilibrium`, not `converged`

`converged` is the strict band — on top of `equilibrium`'s zero-mean motion
it requires every `|dH| < dh_zero` *and* low entropy across the whole
window. A value **held** at a low-entropy constant from the start reaches
it (a value pinned at `0.0` for ten observations reports `converged`). But
a residual that *decays* into rest does **not**: empirically it reads
`equilibrium` and stays there — the real Gauss-Seidel residual below holds
`equilibrium` even once `change == 0`, verified out to iteration 25, long
after its window has gone quiet. The settling *history*, not just the final
value, decides `converged` vs `equilibrium` — so for an iterative residual,
do not wait for `converged`; treat `equilibrium` as settled too. Real
Gauss-Seidel on a 3×3 system `Ax = b` (`dynamics/solve.eigs`):

```
# observing the residual `change`, report per iteration:
  iter 1   change=0.921875       report=stable
  iter 4   change=0.00854…       report=stable
  iter 7   change=1.67e-05       report=stable
  iter 8   change=2.09e-06       report=equilibrium   <- solved (x ≈ [1,1,1])
  iter 9+  change → 0            report=equilibrium   (stays equilibrium, even
                                                       at change == 0 — never
                                                       reaches "converged")
```

So `loop while not converged` here **never terminates** — it runs to the
iteration cap on a system solved by iteration 8 (the recipe below fixes
this).

### An oscillatory residual flickers settled mid-swing

A residual swinging toward its limit (PageRank power iteration) shows a
*single* `equilibrium` reading mid-swing, well before it is actually
settled. Real PageRank on a 3-node graph (`dynamics/solve.eigs`):

```
  iter 2   change=0.1667   report=equilibrium   <- transient! true answer
                                                    is ~25 iters away
  iter 4   change=0.0833   report=stable
  iter 5   change=0.0417   report=stable
  ...      (stable / equilibrium / improving alternate as it swings) ...
  iter 27  change=4.07e-05 report=equilibrium   <- genuinely settled
```

A naive "stop on the first settled reading" quits at iteration 2 with
`change ≈ 0.17` — completely wrong. The fix is to **debounce**: require the
settled reading to *hold* for several consecutive iterations; a transient
blip resets the count.

### Robust convergence-loop recipe

Combine the two fixes — settled = `converged` OR `equilibrium`, plus a hold
counter. This is exactly what `dynamics/solve.eigs` uses across Jacobi,
Gauss-Seidel, power iteration, and PageRank (`HOLD = 3`):

```eigenscript
define settled(status) as:
    if status == "converged":
        return 1
    if status == "equilibrium":
        return 1
    return 0

hold is 0
it is 0
loop while hold < 3:                # require the settled reading to hold 3×
    # advance the system, then assign the residual you test (`change`) LAST,
    # immediately before `report` — a bare predicate / report reads the most
    # recently assigned top-level value (see Inputs: `g_last_observer`), so an
    # intervening assignment repoints it.
    change is next_residual of state
    status is report of change
    if (settled of status) == 1:
        hold is hold + 1
    else:
        hold is 0
    it is it + 1
    if it >= max_iters:             # always keep an absolute cap as a backstop
        hold is 3
```

Use the bare `loop while not converged` only for a value you know converges
gently and monotonically; for any iterative residual, reach for the
settled-plus-hold form above.

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
- [`InauguralSystems/dynamics`](https://github.com/InauguralSystems/dynamics)
  — the consumer that surfaced the "Convergence loops in practice" guidance
  (`solve.eigs`, `physics.eigs`; findings F-DYN-2 / F-DYN-6 in its
  `FINDINGS.md`)
