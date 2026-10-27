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

These are **trajectory claims, not snapshot claims.** On the numeric channel,
`improving` means a decreasing value whose progress is contracting (lower is
better); on the entropy channel it means "the value has been getting more
determined *over its recent history*." Neither means merely that the last
single step happened to go down. The canonical use is a
loop condition — `loop while improving`, `loop while not stable` — which
must be robust to a single noisy tick. That is why every predicate reads
a **window** of the last `N` observations rather than the instantaneous
`dH`. (The original observer semantics were trajectory-based; the early C
runtime simplified five of the six to single-step checks, which flickered
under noise — see "Pointwise behavior replaced" in each section.)

## What each predicate is graded against (#1754)

The question each predicate answers is decided on #1754 (a `kind:decision`
issue: owner intent lives there, per [`docs/PRINCIPLES.md`](PRINCIPLES.md)
§0); the provenance of each is recorded in its comment 6178341982.
`definitions` in `tools/observer_oracle/corpus.json` is the machine-readable
form of those decisions: the full rule and the cited sources for each
question. Its lines marked "OUR derivation" or "OUR documented choice" are
the modelling choices recorded on #1754, not part of the cited texts.
`make observer-oracle` grades the runtime against them, and
[`docs/OBSERVER.md`](OBSERVER.md) ("Graded against mathematics") describes
the oracle.

| Predicate | Class | Source | Decided by | The question |
|-----------|-------|--------|------------|--------------|
| `converged` | CONVENTION | numpy `isclose` | the standard answer, under the owner's delegation for inherited names | From checkpoint n on, does the value stay within ε of a point? |
| `stable` | CONVENTION | settling time (control theory) | the standard answer plus measured usage, under the delegation | From n on, does the value stay within a band about where it is heading? |
| `improving` | CONVENTION | Keras `EarlyStopping` (`mode='min'`), Hardy §62 | the owner's ruling: directional, lower is better; corrected to "eventually bounded" | Did the value set a new best (lower) within the window, and is the sequence eventually bounded? |
| `oscillating` | MATH | Hardy §62 | the mathematical definition (no choice) | Does the sequence tend neither to a limit nor to +∞ or −∞? |
| `diverging` | MATH | Hardy §60, Rudin Def. 3.15 | the mathematical definition (no choice) | Does the sequence tend to +∞ or −∞? |
| `equilibrium` | MATH | NIST e-Handbook 6.4.4.2 | the standard answer, under the delegation; the deterministic case is OUR derivation | Is the sequence weakly stationary: a constant mean and variance, an autocovariance that depends only on the lag? For a deterministic sequence that means constant, so a random walk (constant mean, growing variance) is not in equilibrium, and neither is a settled but still-moving decay. |

MATH "does the sequence have a limit" (Hardy §58, Rudin Def. 3.1) is reported
beside `converged` but not scored: no windowed observer can decide it at n.

**NaN.** At a checkpoint whose current value is NaN, every predicate is
false: the #1758 O2 convention (NaN is undefined), not a MATH answer. The
oracle labels such a checkpoint CONVENTION for all six predicates, citing
#1758, whatever the whole sequence does. It is the one recorded exception to
one question per predicate.

**The bands below are not those definitions.** They are the runtime's current
windowed tests of the last `N` observations. Two limits are inherent: a window
cannot see the values after n that `converged` and `stable` ask about, nor the
whole sequence that `oscillating` and `diverging` describe. Beyond that, the
runtime answers a different question for two predicates:
- `improving`: the directional band approximates the convention's new lower
  best by more than `min_delta` within the window on an eventually bounded
  sequence, but is narrower: it requires every raw step to be negative and
  both the mean and maximum step magnitudes to contract to at most 0.7× their
  values in the older half of the window.
- `equilibrium`: the band tests that the window's relative steps have
  near-zero mean and variance, so a sequence whose steps have died down reads
  `equilibrium` although it is not constant (a decay settling on a limit,
  Newton's iteration for √2, even the slowly growing harmonic series), which
  the definition says it is not.

The per-predicate tables `make observer-oracle` prints measure all of this.

## Which channel answers (#861)

The predicate words and `report` are **routed**: a binding whose most
recent observed assignment is **numeric** answers from the **value
channel** — the classifier below, over relative steps
`rel = Δv / max(|v|, |v_prev|, scale)` (#1045); every
other binding (strings, containers) answers from the **entropy channel**,
the windowed formulas in "The six predicates". `report_value of x` is the
value-channel classifier by name (identical to the routed words on a
numeric binding — the two surfaces cannot disagree); `classify of
[t, "entropy"]` reaches the entropy classifier by name. The entropy
MEASUREMENT — `where`, `why`, `how`, trajectory snapshots, container
folds, the tape — is unchanged everywhere.

Why: entropy is a function of `|x|` alone, so any clause on it is a
clause on magnitude. The current CI corpus compares every predicate, not
just `converged`, against its labelled question. Run
`python3 tools/observer_oracle/score.py src/eigenscript` and read its
**DOCUMENTATION TABLE** for the per-predicate incumbent, `REFERENCE`,
`REFERENCE_ENTROPY`, and constant-false scores. The command derives every
cell from the corpus and the selected binary; no score is copied into this
document. The entropy channel can certify a geometric runaway and can fail
to certify a finite nonzero limit because magnitude is a lossy proxy for
motion.

**The numeric definitions** (a fixed window of `N = 10` relative steps — see
[The window](#the-window-1044) — `rel = Δv / max(|v|, |v_prev|, scale)`, raw
steps `Δv` kept alongside — #422):

| band | fires when |
|---|---|
| `converged` | full window, every `\|rel\| < dh_zero`, raw guards clean |
| `stable` | full window, every `\|rel\| < dh_small`, no strong consecutive sign flips |
| `equilibrium` | full window, `\|mean(rel)\| < dh_zero`, `variance(rel) < dh_zero²` |
| `improving` | ≥ 4 samples, **decreasing** raw steps whose mean *and* max contract to ≤ 0.7× the older half — lower is better; a summable (geometric-class) tail genuinely closing on a limit |
| `diverging` | value at the saturation ceiling (any window fill), or non-vanishing same-sign raw steps (a linear/polynomial runaway whose `Δv/\|v\| → 0` is still unbounded) |
| `oscillating` | ≥ 4 deadband sign-flips of `rel`; or non-vanishing raw alternation (a perpetual oscillation below the deadband is still an oscillation); or **window-scale folding** — ≥ 2 direction reversals with net travel ≤ 0.3× path length and motion above the deadband (a sinusoid sampled slower than its half-period) |

**Modulated raw steps (#1891).** The historical half-window mean rule is
kept. With only `N = 10` samples, it cannot separate a slowly modulated decay
from a modulated constant-envelope runaway, so replacing it would merely move
silent wrong answers between the two classes. Measurements on the real binary
used steps `c*E^k*(1+m*cos(w*k+θ))`, 16 phases, both signs, and checkpoints
4–60. The false-`diverging` rates for decay were 0.4% at `E=0.9, m=0.3,
w=2`; 19.5% at `E=0.94, m=0.84, w=2` (the #1891 class); 45.0% at
`E=0.99, m=0.84, w=2`; and 49.3% at `E=0.999, m=0.84, w=2`. For runaways,
`G=1` (constant envelope), `m=0.3` or `0.84`, `w=2` read `diverging` on
50.0% of reads, while `G=1.05, m=0.84, w=2` read `diverging` on 73.1%.
These scored disagreements are the documented residual, not waived oracle
floor losses. More observer memory than `N = 10` is the open direction on
#1891.

The quiescent lattice on this route has `converged ⊂ stable`. A converged
one-direction tail is not `equilibrium`: its deterministic mean still has a
trend, even though its remaining motion is below the convergence deadband.
The rest bands exclude the raw structure tests; the motion bands are mutually
exclusive. `report` resolves the canonical priority `oscillating →
diverging → improving → converged → equilibrium → stable → moving`.

**The relative step is scale-free (#1045).** `rel` divides the raw step
by the step's own local scale, `max(|v|, |v_prev|)`, floored at the
runtime state's characteristic scale (`0.001` in a normal run). Above the
scale a verdict is **unit-free**: one physical
trajectory stored in radians, degrees or milliradians reads the same
(phugoid's spiral mode — bank angle `0.0124 rad = 0.71 deg = 12.4 mrad`,
halving every 14.9 s, replayed at 1 Hz — reads `moving` in all three;
`tests/test_observer_window_scale.eigs`). Below the scale the deadband
turns absolute: `|Δv| < dh_zero · scale` (`1e-6` by default), so
rounding noise around an exact zero (`Δv ~ 1e-16`) is not motion, and a
geometric decay toward zero keeps `rel = 1 − r` — `improving`, never
`converged` — until it is inside the scale. Read as the textbook
criterion, `converged` is `|Δx| ≤ rtol·|x|` with `rtol = dh_zero` and an
absolute floor `atol = dh_zero · scale`. The previous step,
`Δv/(1+|v|)`, was the entropy formula's normalisation borrowed as a step:
below `|v| ~ 1` it was just `Δv`, an absolute deadband, and the unit the
consumer stored the value in decided the verdict. The scale is the one number a unit choice still touches; the runtime uses it
as the fixed absolute floor. Why the local scale and not the
window's running maximum: for a monotone decay that maximum is the
*oldest* sample, so `rel = (1−r)·r^(N−1)` and any ratio under ~0.5 would
certify `converged` at the first full window no matter how far from its
limit the value still was (`1e6·0.3^k` at `x ≈ 1.8`) — and a wider window
would make it worse.

**The honesty bound.** `converged` is a **stopping criterion, not a
proof**: it means *settled at the deadband* — every recent step below the
tolerance — which is the strongest claim a finite window supports.
Vanishing steps do not imply a limit (the harmonic series' steps vanish;
its sum does not), so a slow-enough divergence will eventually read
`stable` and, at extreme patience, `converged`; and a slowly-converging
sequence reads `converged` while still `~1e-2` from its limit (corpus
cases 6 and 8). The deadband is the tolerance knob:
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
| `dh_window` | ring buffer of the last `N` `dH` values (`N` = the window depth in force, 10 by default — [The window](#the-window-1044)) | `observer_window_push` in `update_observer` |
| `obs_age` | number of observations since the value first existed | `update_observer` |

The ring buffer is allocated lazily on the *second* observation (the
first push only happens once `obs_age >= 1`), so a binding
assigned exactly once pays no allocation. Note the gate is the second
*observation*, not interrogation: a binding nothing ever queries still allocates
its window on its second assignment, because the observe op is emitted
unconditionally (see [OBSERVER.md](OBSERVER.md#cost)). `unobserved:` is what
avoids it. they cannot be tracked across resets.

**What `unobserved:` elides, precisely (#1049).** An assignment inside the
block still records its **value-channel** sample: a scalar's relative and
raw step enter `v_window`/`vr_window` and `last_value` moves (O(1) — one
subtraction, one division, two ring writes), and a non-numeric value flips
the route bit exactly as an observed one would. So the window the numeric
route reads is complete, and every verdict on that route — the six
predicates on a numeric binding, `report`, `report_value`, a `trajectory`
snapshot's `rel`/`raw` — is **identical with and without the block**
(an elided `b is 0.0` initialiser no longer moves the window-fill
boundary by one read; one elided step mid-stream no longer perturbs the
next ten verdicts). What the block does not compute is the entropy walk
and everything built on it, so these remain **elision-sensitive**:

| Reader | Why it can differ under `unobserved:` |
|---|---|
| `why is x`, `how is x` | read `dH`, which the block never updates |
| `observe of x` | its `dH`/`prev_dH` elements; the band is routed like `report` |
| `trajectory of x` | the `dh` list, `dH`, `last_entropy` (`rel`/`raw`/`last_value` are complete) |
| `classify of [t, "entropy"]` | the explicit entropy channel |
| `report` / the six predicates on a **non-numeric** binding | the entropy route — its `dh_window` is missing the elided steps |
| the loop stall backstop | reads the last observed slot's `dH` |
| a **bare** predicate | reads the last **observed** binding — the alias is deliberately not moved by an elided assignment, so scratch work inside the block cannot hijack a `loop while not converged` |

`where is x` is unaffected: it is recomputed from the current value at
ask time (#711). A predicate asked *inside* the block still raises (#871).

One consequence: `unobserved:` is no longer a way to **declare** a numeric
binding without putting a sample in its window (the pre-#1049 idiom in
`lib/experiment.eigs`, which seeded `tracker is 0` inside a block so the
seed-to-first-reading jump would not sit at the head of the trajectory).
Seed with `null` instead — null and boolean assignments are never sampled,
on either path — and the first real reading is the first observation:

```eigenscript fragment
define first_stable(values) as:
    tracker is null            # declares the binding; not a sample
    for v in values:
        tracker is v
        if stable of tracker:
            return v
    return null
```

`window` below means the `dh_window` contents oldest→newest;
`count = window_size(v)` is how many real samples it holds (≤ N).

## Thresholds

Three numbers from `EigsState` (defaults shown):

```
dh_zero  = 0.001   |dH| below this is "essentially zero change"
dh_small = 0.01    |dH| below this is "small but nonzero change"
h_low    = 0.1     entropy below this is "low information content"
```


A fourth number, the value channel's characteristic scale (#1045):

```
scale    = 0.001   |v| below this counts as "at zero": rel = Δv / max(|v|, |v_prev|, scale)
```

See "The relative step is scale-free" above for what it means.

Two derived window constants (for the fixed window depth `N = 10`):

```
VOTE  = 0.6                min fraction of genuine same-direction steps for improving/diverging
FLIPS = ceil(N / 3)  = 4   min sign-flips in the window for oscillating
```

## The window (#1044)

Every predicate classifies over the last `N = 10` **samples** — observed
assignments, not seconds. The depth is fixed by `OBSERVER_WINDOW_N`; a window
must be full before a quiet verdict such as `converged` can fire.

```eigenscript fragment
window is 10
```

**Time versus samples.** A mode slower than about ten samples of the consumer's
cadence cannot fold inside the window. Choose an observation cadence that puts
at least one period of the slowest mode inside those ten samples (`10 ≥ T / Δt`).
A mode much faster than the cadence can alias too, so sample fast enough to
preserve its reversals. The ring stores ten doubles per channel per binding
(the value channel keeps two), and folding/variance tests are `O(10)` per
verdict asked, not per assignment.

## Configuration recorded on older tapes

Tape formats retain observer-configuration events so recordings made when the
configuration builtins existed still replay deterministically. Ordinary source
programs cannot emit those events now; live runs use the fixed thresholds,
ten-sample window, and characteristic scale above.

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
| `stable` | ✅ shipped (`observer_slot_stable`, `vm.c` kind 1 + report) | #205 (done) |
| `oscillating` | ✅ shipped (`observer_slot_oscillating`, `vm.c` kind 3 + report) | #206 (done) |
| `improving` | ✅ shipped (`observer_slot_improving`, `vm.c` kind 2 + report) | #207 (done) |
| `diverging` | ✅ shipped (`observer_slot_diverging`, `vm.c` kind 4 + report) | #208 (done) |
| `equilibrium` | ✅ shipped (`observer_slot_equilibrium`, `vm.c` kind 5 + report) | #209 (done) |

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

This section defines the entropy-channel predicate. The routed numeric
predicate is the directional band in the numeric table above: values must be
decreasing because `improving` follows the ML loss convention that lower is
better. Contracting upward steps never qualify, including growth to a plateau.

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
- **The numeric value-channel quiescent bands.** For a numeric binding,
  `converged`, `equilibrium` and `stable` read the window's relative steps
  and NEVER the entropy. All three need a full window, and none fires on a
  raw runaway or a raw oscillation.
  - `converged ⊂ stable`. Every relative step under the settle deadband
    implies every step under `dh_small`, with no sign flip above the deadband.
  - `equilibrium` is not implied by `converged`. It needs balanced motion,
    meaning a window mean and variance under the deadband. It also rejects a
    one-direction trend: at least two nonzero raw steps, all of one sign.
    Exact-zero steps are neutral.

  Concretely, a full window whose relative steps are all under the deadband
  is one of:
  - **balanced or settled** (raw steps mixed in sign, or exactly zero) →
    `converged`, `equilibrium` and `stable` (`report` → `converged`);
  - **a one-direction tail** → `converged` and `stable` but not
    `equilibrium` (`report` → `converged`).

  `equilibrium` can fire without `converged`. A balanced window whose mean
  and variance are under the deadband can still hold individual steps above
  it. A `stable` window that is not `converged` has every step under
  `dh_small` but some above the deadband: small, steady motion.
- **The entropy-channel quiescent bands have a separate lattice.** Entropy
  predicates operate on the `dH` window and do not apply the numeric route's
  raw-value-step trend guard. When a full low-entropy window has every
  `|dH| < dh_zero`, both `converged` and `equilibrium` are true, including
  when all its nonzero `dH` steps point in one direction (`report` →
  `converged`). At high entropy, `equilibrium ⊂ stable` as before. Thus the
  entropy route permits `converged` and `equilibrium` to co-fire for a
  same-direction quiet window; the numeric value route deliberately does not.
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
```output
converged
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

```eigenscript fragment
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

```eigenscript fragment x=1.0 rate=0.5 k=0
loop while not converged:
    x is x * rate     # the quantity you mean
    k is k + 1        # observed last → the bare predicate now reads k
```

`k` increments steadily, its entropy flattens at a fixed step count
regardless of `rate`, and the loop halts on `k` — not `x`. (This is exactly
how `dynamics`' `settle_steps` returned the same count for every rate.)

Name the subject with the **named form**:

```eigenscript fragment x=1.0 rate=0.5 k=0
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

```eigenscript fragment
x is 100.0
for i in range of 20:
    x is x * 0.999        # genuine motion, but each step is ~0.1%
report of x               # "converged"  — settled AT THE DEADBAND; x is ~98, not ~0
```

This is the tolerance semantics, not a defect: `converged` means every
recent step is below the tolerance, and per-step motion of 0.1% at the
fixed `dh_zero = 0.001` is exactly the boundary. This tolerance is not a
runtime setting; read its authoritative value at
`OBSERVER_DH_ZERO_DEFAULT` in `src/eigenscript.h`.

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

```eigenscript fragment
x is 100.0
for i in range of 13:
    x is x * 0.7          # 100 → ~1: steps contracting toward a limit
report of x               # "improving"
```

```eigenscript fragment
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

```eigenscript fragment x=1.0 next_step='(v) => v * 0.5'
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

```eigenscript fragment x=1.0 next_step='(v) => v * 0.5' max_iters=200
it is 0
loop while not (converged of x):
    x is next_step of x
    it is it + 1
    if it >= max_iters:
        throw of "did not settle"
```

- **Tolerance tighter than the fixed value.** `converged` fires at the
  deadband (`dh_zero`, fixed at 0.1% relative). It is not configurable;
  read the authoritative value at `OBSERVER_DH_ZERO_DEFAULT` in
  `src/eigenscript.h`. For a tighter answer, calculate and test the desired
  residual explicitly.

## What carries a trajectory

Observer trajectory is keyed to an **environment slot** — `env_obs_slot(Env *e,
int idx)` returns `e->obs[idx]`, and the Value itself carries no observer
state. So every predicate, `report`, `report_value`, `observe` and
`trajectory of x` answer about a *binding*, and only a binding that persists
across the observations has a history to classify (#1048). Every case
follows from that one rule:

**A binding's creation is its first observation: the `local`/first assignment
for a local, and the call-time binding for a parameter. Every later assignment
in the same activation adds one.** Thus, for every binding in an activation,
`when` = (1 if it is a parameter) + the number of tape `A` records for it in
that activation. The parameter creation event is #1048's “one observation per
call”; it is not an `A` assignment record.

| form | persistent env slot? | trajectory |
|---|---|---|
| a named local (`q is v`, `local q is v`) | yes | **carries** |
| a closure-captured local (one factory call per entity) | yes — each call is its own `Env` | **carries**, N chosen at runtime |
| an `eval`-generated name | yes | carries, N chosen at runtime (loses lint and the AOT — prefer the closure) |
| a dict field `ch.a` | no — a Value in a container | none: `equilibrium`, no history |
| a list element `xs[0]` | no — a Value in a container | none |
| a function parameter | the frame dies each call | carries within that call; creation is observation one (#1048) |
| a `for` binder `for x in xs:` | fresh each iteration (#1062) | none |
| a `for`-body `local` **at module level** | the loop env is cleared each iteration | none: one observation, every read answers `equilibrium` |
| a `for`-body `local` **inside a function** | a frame slot that persists for the loop | carries — and **interleaves** if fed several entities |
| a `for`-body plain `q is …` | creates in the enclosing scope, persists | carries — and interleaves |
| a `loop while`-body binding (plain or `local`) | one env, persists | carries — and interleaves |

The last three rows are the sharp edge. The obvious per-entity read

```eigenscript nocheck the body is elided with an ellipsis; this shows binding identity, not a runnable program
loop while i < n:
    local q is fleet[i][2]        # ONE binding, rebound n times
    if diverging of q: ...
```

does not lose resolution — it **manufactures verdicts**: the slot's window is
the round-robin interleave of every entity it visits, so a monotonically
decaying entity reads `oscillating`. Lint `W024` names this shape — including
the common `local q is fleet[i][2] + 0.0` spelling, where the projection sits
under arithmetic — and the module-level `for` variant, whose reads always
answer `equilibrium`. The
mirror form is fine: a *fixed* field or element copied into a binding each
tick (`local e is game.energy`) is exactly how a container field is given a
trajectory.

**The recommended per-entity form is a closure per entity** — one `Env`, and
so one slot, per factory call, in ordinary static source that lints and
compiles like anything else:

```eigenscript
define make_ch as:
    local q is 0.0
    define step(v) as:
        q is v
        return report_value of q
    return step

fleet is [["a", 0, 100.0], ["b", 0, 1.0]]
chans is [make_ch of [], make_ch of []]
t is 0
loop while t < 40:
    fleet[0][2] is fleet[0][2] * 0.9      # decaying
    fleet[1][2] is 0.0 - fleet[1][2]      # sign-flipping
    a is (chans[0]) of fleet[0][2]
    b is (chans[1]) of fleet[1][2]
    t is t + 1
print of (a + " " + b)                    # improving oscillating
```
```output
improving oscillating
```

A named binding per entity (`qa is fleet[0][2]`, `qb is fleet[1][2]`) is the
same thing when N is fixed at authoring time. Container-keyed trajectory
(dict fields and list elements carrying their own slot) is a ROADMAP item,
not a current capability.

## Cost

The `dh_window` costs one `xcalloc(N * sizeof(double))` (80 bytes at the
default N=10; the depth in force at the first push, see [The
window](#the-window-1044)) per *interrogated* value, lazily on the second
observation. Per assignment
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
