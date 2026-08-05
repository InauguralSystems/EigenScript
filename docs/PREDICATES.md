# Predicates

The bare predicate words — `converged`, `equilibrium`, `stable`,
`improving`, `diverging`, `oscillating` — and the `report of x` builtin
classify a value's recent trajectory into one of those bands (`report` adds
one label the predicates don't have: `moving`, for a full window in which
none of the six is true — see [The `report` builtin](#the-report-builtin)).
Each
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

## Which channel answers (#861)

The predicate words and `report` are **routed**: a binding whose most
recent observed assignment is **numeric** answers from the **value
channel** — the classifier below, over relative steps `Δv/(1+|v|)`; every
other binding (strings, containers) answers from the **entropy channel**,
the windowed formulas in "The six predicates". `report_value of x` is the
value-channel classifier by name (identical to the routed words on a
numeric binding — the two surfaces cannot disagree); `classify of
[t, "entropy"]` reaches the entropy classifier by name. The entropy
MEASUREMENT — `where`, `why`, `how`, trajectory snapshots, container
folds, the tape — is unchanged everywhere.

Why: entropy is a function of `|x|` alone, so any clause on it is a
clause on magnitude. Measured against 27 analytically-known sequences
(`tests/test_convergence_oracle.eigs`), the entropy channel scored 19/27
— `converged` fired across the whole region `|x| ∈ [77, 1e307]` (a
geometric runaway certified at `x ≈ 2.9e5`), could never fire for limits
in `[~0.013, 76]` (Newton's method to `sqrt(2)` was uncertifiable), and
gave the same computation targeting 5000, 5 and 0.005 three different
verdicts. The value channel scores 25/27; the two misses are the
irreducible tolerance floor, not defects (see the honesty bound below).

**The numeric definitions** (window `N = 10` relative steps
`rel = Δv/(1+|v|)`, raw steps `Δv` kept alongside — #422):

| band | fires when |
|---|---|
| `converged` | full window, every `\|rel\| < dh_zero`, raw guards clean |
| `stable` | full window, every `\|rel\| < dh_small`, no strong consecutive sign flips |
| `equilibrium` | full window, `\|mean(rel)\| < dh_zero`, `variance(rel) < dh_zero²` |
| `improving` | ≥ 4 samples, **monotone** raw steps whose mean *and* max contract to ≤ 0.7× the older half — a summable (geometric-class) tail, genuinely closing on a limit |
| `diverging` | value at the saturation ceiling (any window fill), or non-vanishing same-sign raw steps (a linear/polynomial runaway whose `Δv/\|v\| → 0` is still unbounded) |
| `oscillating` | ≥ 4 deadband sign-flips of `rel`; or non-vanishing raw alternation (a perpetual oscillation below the deadband is still an oscillation); or **window-scale folding** — ≥ 2 direction reversals with net travel ≤ 0.3× path length and motion above the deadband (a sinusoid sampled slower than its half-period) |

The quiescent lattice on this route: `converged ⊂ equilibrium` and
`converged ⊂ stable` (all-under-deadband satisfies all three). The rest
bands exclude the raw structure tests; the motion bands are mutually
exclusive. `report` resolves the canonical priority `oscillating →
diverging → improving → converged → equilibrium → stable → moving`.

**The honesty bound.** `converged` is a **stopping criterion, not a
proof**: it means *settled at the deadband* — every recent step below the
tolerance — which is the strongest claim a finite window supports.
Vanishing steps do not imply a limit (the harmonic series' steps vanish;
its sum does not), so a slow-enough divergence will eventually read
`stable` and, at extreme patience, `converged`; and a slowly-converging
sequence reads `converged` while still `~1e-2` from its limit (corpus
cases 6 and 8). The deadband is the tolerance knob:
`set_observer_thresholds of [dh_zero, dh_small, h_low]` — `dh_zero` is
the settle tolerance, `dh_small` the small-motion band; the raw
STRUCTURE tests are deliberately threshold-free (a perpetual ±5 swing is
an oscillation at any tolerance). `h_low` affects only the entropy
route.

## Inputs

Every predicate reads the same observer state on the most recently
assigned top-level value (`g_last_observer`):

| Field | What it is | Computed by |
|-------|-----------|-------------|
| `entropy` | current information content `where is x` — **recomputed from the value present at ask time** (#711), so in-place mutation is visible | `compute_entropy_impl` via `observer_entropy_now` |
| `dH` | change since previous observation `why is x` — a trajectory of **assignments**; mutation does not move it, and a query never writes back | `update_observer` (`new − last`) |
| `prev_dH` | the previous step's `dH` | `update_observer` |
| `dh_window` | ring buffer of the last `OBSERVER_WINDOW_N` (=10) `dH` values | `observer_window_push` in `update_observer` |
| `obs_age` | number of observations since the value first existed | `update_observer` |

The ring buffer is allocated lazily on the *second* observation (the
first push only happens once `obs_age >= 1`), so a binding
assigned exactly once pays no allocation. Note the gate is the second
*observation*, not interrogation: a binding nothing ever queries still allocates
its window on its second assignment, because the observe op is emitted
unconditionally (see [OBSERVER.md](OBSERVER.md#cost)). `unobserved:` is what
avoids it. Arena values skip the buffer entirely —
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
`N` for the rest bands (`converged`, `stable`, `equilibrium`) on both
routes, `4` for the value route's motion bands (the half-split needs two
samples per half) and `3` for the entropy route's. A two-write program can
never report any predicate true; this is the single most important
difference from the old pointwise rule, which fired on the first step.
**One exception**: `diverging` fires at the numeric ceiling regardless of
window fill — see the saturation rule below.

## Opaque rule (#708): function-valued bindings

A binding whose CURRENT value is a function or builtin is outside what
the observer measures — a function has no content to sample, so its
entropy is a constant and dH can never move. On such a binding **every
predicate returns `false`** and `report`/`report_value`/`observe`'s
band answer **`opaque`** (a label outside the six-band lattice, like
`moving`). Rebinding `f` from one function to another therefore no
longer classifies `equilibrium`; it names the gap. The entropy constant
itself is unchanged: functions inside containers contribute exactly the
size/average terms they always did, and no numeric trajectory measures
differently. The check reads the binding's current value at ask time —
rebind `f` to a number and its numeric trajectory (which was recorded
all along) answers normally again.

## Saturation rule (#861): bindings at the numeric ceiling

Overflow saturates at `±1e308` (`num_guard`, the "finite by construction"
rule), which turns an unbounded trajectory into a **fixed point**. Once a
runaway pins there, `dH` is exactly 0 in the entropy channel and the
relative step is exactly 0 in the value channel, and `H(1e308)` sits far
under `h_low` — so every clause of `converged` is *legitimately* satisfied.
The window really is quiet. The quiet is an artifact of the clamp, formed
after the evidence of divergence was already destroyed.

So a binding whose last observed number has `|value| >= 1e308` is treated
as **diverging, and in no rest band**:

| predicate | at the ceiling |
|---|---|
| `converged`, `equilibrium`, `stable`, `improving` | forced `false` — a value at the clamp is not resting or approaching |
| `diverging` | forced `true`, **including on a partial window** |
| `oscillating` | evaluated normally — a value flipping `±1e308` reads as the oscillation it is, and `report`'s priority resolves it to `oscillating` |

Since #861 both `report` and `report_value` run the same classifier, so
they agree here by construction. (The `H(x) ≡ H(−x)` blindness that once
made them disagree at the ceiling — #862 — still exists in the entropy
SIGNAL, but no numeric classification reads it anymore; it is visible
only through `classify of [t, "entropy"]` and for non-numeric bindings,
whose values have no ceiling.)

`diverging` is claimed before the partial-window guard because the
evidence is the value's *position*, not the shape of the (flattened)
window — this is the one place a predicate fires on fewer than 4 samples.

**A literal `±1e308` that never overflowed reads `diverging` too.** The
runtime cannot distinguish a saturated value from one deliberately
assigned the ceiling (#865: the saturated value compares equal to itself
under further growth, so no in-language predicate separates them). Of the
two possible errors this is the loud one: a diverging solver that reports
`converged` returns `1e308` *as an answer*, while a deliberate ceiling
constant reported as `diverging` is a visible false alarm. Below the
ceiling nothing changes — `1e307` held constant still converges.

As with the opaque rule, the entropy *constants* are untouched: this is a
classification gate, not a change to what entropy measures. It lives with
the predicates rather than in the VM (contrast #708, which must read the
binding), so the tape, DAP, and step surfaces inherit it.

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

Since #861 the kinds dispatch by route: a numeric binding answers from
the value-channel definitions in "Which channel answers" above; the
windowed-entropy formulas in the next section serve non-numeric bindings
and the explicit `classify of [t, "entropy"]` channel. `report_value of
x` (#294) is the value-channel classifier by name — on a numeric binding
it and the predicate words are one classifier and cannot disagree.

## The six predicates — the ENTROPY route

**These formulas classify the trajectory of `entropy(value)`. Since #861
they answer only for non-numeric bindings (strings, containers) and the
explicit entropy channel; numeric bindings use the value-channel
definitions above.** The traces and design notes are kept because the
mechanics still run — on the signal they were always sound for.

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
  monotone net trend (improving/diverging) cannot have. (At the numeric
  ceiling `diverging` is forced true from the value's *position* rather
  than the window's trend, so it is the one case where both can hold at
  once: a trajectory that moves in and out of the ceiling and lands on it
  has real `dH` sign changes AND a saturated last value. `report`'s
  priority order resolves that to `oscillating`, the more specific claim.)
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
  equilibrium is one with steady directional drift (mean `|dH| > dh_zero`)
  **at high entropy**: moving a little, but settled.
- **The bands are not exhaustive.** A full window with steady gray-band
  drift at *low* entropy fires nothing: the steps are under `dh_small` so
  `improving`/`diverging` are excluded by the #187 rule, the mean is over
  `dh_zero` so `equilibrium`/`converged` are excluded, and `stable`'s
  `entropy >= h_low` clause excludes it too. That state is real (a value
  decaying toward zero is in it) and it has no predicate — `report` names
  it `moving` (#735). Do not read "no band fired" as "at rest".

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

…and, when none of the six is true at a full window, the residual band:

7. `moving`

These all use the same windowed helpers as the predicates, so
`report of x == "converged"` agrees with `if converged:` on the same value
— **at a full window**. That agreement is the contract: at a full window
the windowed helpers are the *only* authority, so `report` either names a
band whose bare predicate is true, or says `moving`. It never names a band
the predicates deny. (`moving` is also the value channel's residual label,
so both channels answer "not settled, not in any named band" the same way.)

For a *partial* window (`count < N`), the full-window predicates
(`converged`/`equilibrium`/`stable`) are all false by the partial-window
rule, but `report` still needs to say something, so it falls back to an
instantaneous best-effort label: `equilibrium` if the last
`|dH| < dh_zero`, else `stable` if `|dH| < dh_small` at high entropy, else
`stable`. This is the one place `report` can disagree with the bare
predicates, and only while observations are still accumulating — by the
time the window fills, the windowed helpers decide and the two agree.

**#735**: that fallback used to run at *any* window fill, so a full window
in which no band fired was still labelled from the last `dH` alone — a
low-entropy gray-band drift (every step under `dh_small`, so not
improving/diverging; mean over `dh_zero`, so not equilibrium/converged;
entropy under `h_low`, so not stable) reported `equilibrium` while nothing
had settled. A convergence loop written exactly as the settled-plus-hold
recipe below recommends therefore exited early, at rc=0, with a plausible
answer. The fallback is now gated on `count < N`, and the agreement
invariant is asserted directly in `tests/test_predicate_matrix.eigs`
rather than stated only here — which is how it survived.

## Canonical examples

### A held constant certifies — at any magnitude

```eigenscript
x is 1000000
for i in range of 12:
    x is 1000000   # same value 12 times → window fills with zero steps
if converged:
    print of "converged"   # YES — and the same holds for 5, 42, or 0.005
```

Before #861, whether a constant could certify depended on its magnitude
(`entropy < h_low` admitted only `|x| > ~76` and `|x| < ~0.013`). The
value route reads motion, so magnitude is irrelevant.

### Newton's sqrt certifies `converged` (#861)

`sqrt(2)` settles to `1.41421…`; once a full window of relative steps sits
under the deadband it reports **`converged`** — the textbook example of
convergence is certifiable. (Before #861 the `entropy < h_low` clause
blocked every limit in `[~0.013, 76]`, and this section documented the
blindness as intended behavior: "it reports `equilibrium`, not
`converged`." See `tests/test_windowed_converged.eigs` WC4, now pinned to
the certification.)

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

`loop while not converged` reads as the obvious convergence idiom, and
since #861 it is correct for any numeric value that actually settles —
gently, steeply, oscillating on the way in, at any magnitude. What
remains worth knowing: the tolerance semantics (settled ≠ arrived), the
observation-cadence rule, and the divergent-input guard. Every trace
below is a real run.

### Regime tracks per-step `dH`, not distance to the limit

A predicate classifies the *trajectory* by its steps against the
deadband. A quantity that is still moving but observed in tiny per-step
increments has every relative step under `dh_zero` and reads settled —
while still far from its limit:

```eigenscript
x is 100.0
for i in range of 20:
    x is x * 0.999        # genuine motion, but each step is ~0.1%
report of x               # "converged"  — settled AT THE DEADBAND; x is ~98, not ~0
```

This is the tolerance semantics, not a defect: `converged` means every
recent step is below the tolerance, and per-step motion of 0.1% at the
default `dh_zero = 0.001` is exactly the boundary. Tighten the deadband
(`set_observer_thresholds`) or fix the cadence:

The lesson is about **observation cadence**: observe at a rate matched to
the dynamics, not once per micro-step. The robust pattern is to advance the
system several substeps *unobserved* and observe the quantity once per
frame, so each observed `dH` reflects a meaningful step (`dynamics/physics.eigs`
runs `SUB` integration substeps `unobserved`, then observes once per frame
— without this, a damped oscillator, a diverging one, and a steady
oscillation all read `equilibrium` alike).

### The entropy-peak artifacts are gone from numeric classification (#861)

Entropy is the binary entropy of `p = 1/(1+|x|)` — highest at `|x| = 1`
(the *horizon*), falling toward 0 as `|x| → 0` or `|x| → ∞`. On the old
entropy route this made a value shrinking toward 1 read `diverging`
(rising H) and a runaway growing from 1 read `improving` (falling H) —
both artifacts of the signal, not the motion. The value route reads the
motion:

```eigenscript
x is 100.0
for i in range of 13:
    x is x * 0.7          # 100 → ~1: steps contracting toward a limit
report of x               # "improving"
```

```eigenscript
x is 1.0
for i in range of 13:
    x is x * 1.43         # 1 → ~105: non-vanishing same-sign steps
report of x               # "diverging"
```

The formula and its horizon property are unchanged in the MEASUREMENT
(`where is x` at `1.0` is still the maximum) and still classify
non-numeric bindings; `H(x) ≡ H(1/x) ≡ H(−x)` (#862) remains a blind
spot of that signal, reachable via `classify of [t, "entropy"]`.

### An iterative residual certifies directly (#861)

A residual that decays into rest now reads `converged` once its window
settles — the pre-#861 behavior this section used to document (Gauss-
Seidel's residual pinned at `equilibrium` forever, `loop while not
converged` running to the cap on a solved system) was the dead zone.
`dynamics/solve.eigs`' solvers exit through the predicate itself.

### Mid-swing samples read `oscillating`, then certify

A residual swinging toward its limit (PageRank power iteration) reads
`oscillating` while the swings dominate and certifies once a full window
sits under the deadband. The pre-#861 flicker — a single spurious
`equilibrium` at iteration 2, requiring a debounce-and-hold recipe — came
from the entropy signal's instantaneous fallback; the routed classifier
does not produce it.

### Convergence-loop recipe

```eigenscript
loop while not (converged of x):   # named form: reads x, whatever else is assigned
    x is next_step of x
```

Two cases still deserve a guard:

- **Input that may genuinely diverge.** `converged` (correctly) never
  fires on a runaway. The bare form (`loop while not converged`) carries
  the observer stall backstop — ~100 quiet iterations end the loop with
  `__loop_exit__ == "stalled"` — but the **named** form deliberately does
  not (it must not false-halt on the global alias), so give it an
  absolute cap:

```eigenscript
it is 0
loop while not (converged of x):
    x is next_step of x
    it is it + 1
    if it >= max_iters:
        throw of "did not settle"
```

- **Tolerance tighter than the default.** `converged` fires at the
  deadband (`dh_zero`, default 0.1% relative). For a tighter answer,
  lower it first: `set_observer_thresholds of [1e-6, 1e-5, 0.1]`.

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
