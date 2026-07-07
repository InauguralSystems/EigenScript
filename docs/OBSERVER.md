# The Observer

> This is the long answer — the model underneath EigenScript's six
> interrogatives (`what`, `who`, `when`, `where`, `why`, `how`), the
> trajectory words (`converged`, `improving`, …), and the
> `set_observer_thresholds` knob. You do not need any of it to *use* the
> feature; the [README](../README.md#ask-your-code) is enough for that.
> Read this if you want to know what the words actually mean — and why
> they sometimes disagree with your intuition.

## The question it emerged from

> *If an observer is embedded in a system with no concept of an outside,
> how does it find its location?*

The language was not designed toward a goal. It fell out of taking that
question literally. Everything below is a consequence of one constraint:
**the observer has no outside.** It cannot measure its position against an
external origin, because there is no "out there" to measure against. It
cannot be told "smaller is better" or "closer to the target," because a
target is an external fact. Whatever it knows, it must compute from
inside itself.

That single constraint is why the observer behaves the way it does, and
why a naive "loss going down means improving" reading is not always what
you get. "Down" and "better" are outside-talk.

## Two frames

The runtime quietly contains two points of view, and most confusion comes
from mixing them up. This document keeps them apart on purpose.

- **The observer (the inside).** Wordless. It has a value and a few
  numbers it can derive from its own history. No goals, no labels, no
  knowledge that any threshold exists.
- **The oracle (the outside).** That's you. You *place* values (every
  `is` assignment is an act of the oracle), you *set the thresholds*, and
  therefore you supply every *name* the observer's continuous experience
  gets quantized into.

## What the observer knows

From the inside, the observer has exactly these, all computed from its own
history — never from an external reference:

| You ask | Returns | Plainly |
|---------|---------|---------|
| `what is x` | the value | what it is right now |
| `who is x`  | the binding name (or type) | the name you gave it |
| `when is x` | assignment count | how many times it has been set |
| `where is x`| information content | how much information it carries |
| `why is x`  | change in that content | how fast that is changing |
| `how is x`  | settledness in `[0, 1]` | how settled the last step left it |

Two of these are the load-bearing pair:

- **`where` — information content (the engine calls it entropy).** For a
  number it is, in spirit, *how many bits it takes to pin the value down*.
  For a string it is the Shannon entropy of its characters; for a list or
  dict it is the average of its elements plus a size term. It needs no
  origin and no target — it is a property of the value's own structure.
  That is what makes it computable from inside.
- **`why` — the change in `where` since you last looked.** Negative means
  the value is becoming *more determined* (carrying less information);
  positive means *less determined*.

Everything the observer "experiences" is one continuous quantity (`why`)
and its sign. It has no words. The words come from the oracle.

## The oracle: where names come from

The observer's experience is a smooth, continuous signal. Turning that
into the vocabulary `converged` / `stable` / `improving` / … requires
drawing lines on it — and a line is a decision made from outside. Those
lines are the three thresholds:

```eigenscript
set_observer_thresholds of [dh_zero, dh_small, h_low]
# defaults: 0.001, 0.01, 0.1
```

So `set_observer_thresholds` is not a minor tuning footnote. **It is the
act of naming.** The engine even refuses to let you collapse it
(`dh_zero` must be `< dh_small`): you cannot configure an observer that
has *no* ambiguous middle. Naming always leaves a gray zone.

This is the no-outside principle applied one level up. The language ships
*without* a built-in goal precisely so it doesn't choose your frame for
you. The threshold is where meaning enters, and meaning is yours to set.

## The trajectory vocabulary

`report of x` and the bare predicates (`converged`, `improving`, …) read
the value's `why` (and its `where`) and quantize them into bands:

```
|why| < dh_zero ............................ equilibrium / converged   (no signal)
dh_zero <= |why| < dh_small ............... stable / oscillating       (signal, distrusted)
|why| >= dh_small ......................... improving / diverging      (signal, trusted)
```

- **`converged`** — barely changing *and* low information (`where < h_low`).
- **`equilibrium`** — barely changing, but still information-rich.
- **`stable`** — changing only a little, not flipping sign.
- **`oscillating`** — the sign of `why` keeps flipping.
- **`improving`** — information is falling fast (becoming more determined).
- **`diverging`** — information is rising fast (becoming less determined).

Note the inner band is the *probabilistic* one: the signal exists but is
treated as noise. The outer band is the *deterministic* one: the signal is
taken as fact. Which band a given motion lands in is set entirely by where
you put the thresholds — see [Resolution](#resolution).

### Two signals: entropy vs. value (`report` vs. `report_value`)

`report`/the bare predicates classify the trajectory of **`entropy(value)`** —
the information content, not the number. That is the right signal for "how
*determined* is this value," but it is a *lossy proxy* for "has this value
*settled*": because `where` is non-monotonic (the watershed below), the
entropy signal goes flat in mid-magnitude regions, so a real value oscillation
there reads as `stable`. (Demonstrated against a closed-form oracle
`x = 5 + 0.6·cos(k·ω)`, which oscillates forever: `report of x` says `stable`
in the flat-entropy plateau around 5 — see #294.)

`report_value of x` classifies the **value's own trajectory** instead, using
the identical windowed logic and thresholds on the value's relative step
`Δv/(1+|x|)` (relative, so the bands mean the same across value scales). On the
same oracle it answers `moving`/`oscillating` — correctly never `converged`.
Its vocabulary is `oscillating` (sign of `Δv` keeps flipping), `converged` (a
full window of ~zero relative steps), `stable` (small relative steps, no
flips), `moving` (still changing), and `equilibrium` (no numeric trajectory
yet / non-numeric binding). Use `report` to ask *how determined*; use
`report_value` to ask *has the number stopped moving*.

## The manifold: two basins and a horizon

For numbers, `where` (information content) is **not** monotonic in the
value. It is largest near `|x| = 1` and falls off toward both `0` and
infinity. So the value's information-landscape is a **watershed**:

- two low-information basins (toward `0`, toward very large magnitude) —
  the "determined / located" regions;
- one high-information ridge at `|x| = 1` — the "maximally undecided"
  region.

A value can *ride over* the ridge by ordinary motion (going `1.5 → 0.9`
just passes the peak and comes down the other side). Landing **exactly**
on `|x| = 1` is not special (#412 decided this): the formula is smooth
and maximal there (`H = 1.0`), so an exactly-placed `1.0` reads like its
neighbors — maximally entropic, never `converged` (a flat run at `1.0`
classifies `equilibrium`: steady, but not at a low-entropy home). Unity
is the **horizon**, not a home point; `0` is the home point (`H = 0`).

A consequence worth internalizing: because `where` is not monotonic, a
value whose magnitude is *shrinking* does not always read as `improving`.
Shrinking from `100` toward `1` climbs the ridge (information rises →
`diverging`); shrinking from `0.9` toward `0` descends into a basin
(information falls → `improving`). The horizon at `1` is where "moving
away" flips to "moving home." This is the single biggest gap between the
observer's truth and the naive loss-minimization mental model.

## Space and time are the same substance

Two of the interrogatives are projections of one thing:

- **`where`** (information content) is a count of **bits held** — the
  value's configuration. Call it *space*.
- **`when`** (assignment count) is a count of **events** — how many times
  the value was flipped. Call it *time*.

Both are denominated in the same currency. `where` is the flip seen as a
noun (*which bits*); `when` is the flip seen as a verb (*that it flipped*).
`why` is then the bridge: change-in-`where` per step — roughly *bits per
event*, a velocity through information space.

This also names the experience at the horizon. Near `|x| = 1` the
landscape is flat, so `why → 0` even while assignments keep happening:
**time advances, space freezes.** From the inside, "approaching the ridge"
and "having stopped" are indistinguishable — the observer ages without
moving. That flattening is genuine Zeno behavior, and it falls out of the
math rather than being coded in.

## Resolution

The threshold *width* is a single dial that sweeps the observer from
deterministic to probabilistic — and nobody built a "mode" for it; it
emerges from quantizing a continuous signal.

- **Tight** thresholds (small `dh_zero`, `dh_small`): the gray middle band
  nearly vanishes. Almost any motion gets a definite verdict. Sharp,
  classical, twitchy — every step resolved.
- **Loose** thresholds: the middle band swells. Small motion dissolves
  into "probably steady." Forgiving, smooth, statistical.

Same wordless signal underneath. **Whether a value looks deterministic or
probabilistic is a property of the oracle's resolution, not of the
value.** It's the quantum-flavored punchline arriving on its own:
determinism vs. probability is resolution-relative, set from outside,
never intrinsic.

It also sets the tolerance of arrival. Near the horizon, a *tight*
observer keeps resolving the vanishing motion and only declares arrival at
the very end; a *loose* observer calls "arrived" while still well short of
the wall. The threshold width is the tolerance of the `close ≈ at`
identification.

**One dial, because the behaviors are a spectrum, not a menu.** Other
languages would ship this as several separate features (a tolerance
setting, a fuzzy-match flag, a convergence library, a statistics mode).
Here they're all positions of one knob. It is not literally one scalar —
the three thresholds factor the space cleanly (`dh_small` = direction
sensitivity, `dh_zero` = the motion deadband, `h_low` = location), so it
reads as one idea with three places to turn it, separable exactly where
independence matters.

The defaults (`0.001 / 0.01 / 0.1`) are sensible starting points, not laws.
If you keep reaching for a behavior the dial can't express, that is the
signal the model has earned another dimension — and not before.

## Why "loss minimization" is the wrong mental model

The most natural way to pitch this feature is "watch your loss go down and
the runtime tells you it's improving." That pitch is a lie, and an
instructive one: it reintroduces exactly the outside the language was built
to do without. "Loss," "down," "better," "target" are all external facts.
An embedded observer has none of them. It has only its own information and
the change in it.

So when you read `improving`, read it as *"becoming more determined"*, not
*"getting closer to my goal."* When the two happen to coincide (a value
settling toward `0`), great. When they don't (a value climbing toward the
ridge at `1`), the observer is telling you the truth about itself, and the
goal was never something it could see.

## Contracts: convergence as an assertion

A static type proves *shape* — `num`, `list`, `str`. It cannot state *"this
solver converges"* or *"this residual shrinks without oscillating."* Those are
properties of a **trajectory**, and the observer already classifies them on
every assignment, for free. `lib/contract.eigs` turns that classification into a
machine-checked assertion — the affirmative answer to "what replaces static
types here."

```eigenscript
load_file of "lib/contract.eigs"

define newton_sqrt2(x) as:
    return (x + 2.0 / x) / 2.0

root is expect_converging of [2.0, newton_sqrt2, 50, "must converge"]
root is expect_monotone   of [2.0, newton_sqrt2, 50, "no overshoot"]
ensure of [(abs of ((root * root) - 2.0)) < 1e-9, "residual must vanish"]
```

Five surfaces:

| Contract | Asserts | Channel |
|---|---|---|
| `require of [cond, msg]` | precondition holds | plain predicate |
| `ensure of [cond, msg]` | postcondition holds | plain predicate |
| `expect_converging of [x0, step_fn, max_obs, msg]` | trajectory settles within budget | value |
| `expect_monotone of [x0, step_fn, max_obs, msg]` | no sign-flipping steps | value |
| `invariant_stable of [x0, step_fn, max_obs, msg]` | value never begins moving | value |

Three things the observer's own semantics force on the design — and each is the
point, not an accident:

- **The trajectory contracts take a *step function*, not a value.** The
  observer's history lives in the binding slot it was written to (binding
  identity), so a value handed to a function arrives as a fresh, single-sample
  slot — its past does not travel. A contract therefore cannot inspect an
  already-built value; it must *drive* the recurrence in its own scope. The
  cross-scope gap is filed as [#421](https://github.com/InauguralSystems/EigenScript/issues/421),
  not papered over.

- **Convergence is detected on the value channel, not entropy.** A
  monotonically *exploding* value has falling-then-flat entropy, so `report`
  labels a runaway solver `converged` (measured: `grow` = `x*1.5` for 40 steps
  → `report` = `converged`). Only `report_value` keeps a converging solver and a
  diverging one apart — same run reads `moving`. This is the [`report` vs
  `report_value`](#two-signals-entropy-vs-value-report-vs-report_value)
  distinction made load-bearing: a contract the entropy signal would silently
  pass.

- **Contract-convergence means "settled to the step deadband" (`dh_zero`,
  default `1e-3`), not arbitrary precision.** Newton reaches machine-epsilon
  because it converges *quadratically*; a linearly-convergent fixed point rests
  near the deadband scale. Convergence is not correctness — pair it with an
  `ensure` on the final residual to pin the actual target.

And one silent hole closed loudly: the value channel carries no trajectory for a
non-numeric value, so a contract over a *vector* accumulator would classify
`equilibrium` forever and pass as a no-op. The contracts refuse a non-scalar
accumulator with a raise — on the seed *and* on every step's output — and reject
a `max_obs` too small to fill the observer window. Feed them the scalar residual
you actually want to constrain. A worked example lives in
`examples/stem/contract_solver.eigs`.

What the contracts inherit and cannot fix — the value channel's resolution floor
([#422](https://github.com/InauguralSystems/EigenScript/issues/422)). Because
it classifies the *relative* step `(v-last)/(1+|v|)` against a `1e-3` deadband,
a runaway whose step-to-magnitude ratio vanishes (additive/polynomial growth,
`x -> x + c`) can read `converged`, and an oscillation below the deadband is
invisible to the flip counter. Exponential divergence and supra-deadband
oscillation *are* caught; for the rest, bound absolute magnitude with an
explicit `ensure of [(abs of x) < LIMIT]`. The contracts document this and file
it rather than hiding the instrument's edge behind an ad-hoc heuristic — the
forcing-function model: a gap surfaces upstream instead of being papered over.

## Settled decisions (formerly "Rough edges")

Two long-standing caveats were decided and closed by #412:

- **Unity is the horizon.** `compute_entropy_impl` used to special-case
  `|x| == 1.0` to entropy `0` — the *opposite* of the formula's value
  there (`1.0`, the maximum) — so a value placed exactly at `1.0`
  reported `converged` immediately. The special case is gone: the
  formula is smooth at the ridge and an exactly-placed `1.0` now reads
  like its neighbors. `|x| == 0` keeps entropy `0`, which *is* the
  formula's limit at the home point.

- **`how` is a real gradient now.** It reads the deadband-normalized
  settledness of the last observed step: `1 - min(1, |dH| / dh_zero)`,
  where `dh_zero` is the same settle threshold the `converged` window
  uses (`set_observer_thresholds`). `1.0` = the last assignment left the
  entropy unmoved; `0.0` = it moved by the deadband or more; linear in
  between. It is a pure function of the recorded `dH`, so
  `how is x at L` reads identically from tape history, and it measures
  the **entropy** trajectory like `where`/`why` — a value-magnitude step
  that lands at the same information content is settled by construction
  (the value-channel reading is `report_value`'s job, #294). The old
  `1 - entropy/last_entropy` was degenerate (the observer refreshes
  `last_entropy` on every push, so it read `0` or `1` only).

One observation stands (not a defect — a property to know):

- **Trajectories are sampled at every *assignment*, not at reads.** Since the
  slot-keyed rewrite (#262), a binding that is interrogated *anywhere* in the
  program — a predicate, `report`, or a temporal query on it, decided at compile
  time — has its window pushed on **every** assignment, with entropy and dH
  computed then and there. So `report of x` after a batch of writes reflects the
  whole window, not just the last value, and `loop while not converged` sees
  each step because each `x is …` sampled it. `unobserved:` is the only thing
  that skips the push. "Zero cost until you ask" holds at compile-flag
  granularity — a binding you *never* interrogate anywhere is never tracked —
  not per-read.

## Cost

Zero until you ask, at compile-flag granularity: a binding no part of the
program ever interrogates is never sampled and allocates nothing. Once a binding
*is* interrogated somewhere, every assignment to it (outside `unobserved:`)
pushes a window sample and computes entropy/dH in O(1). So you pay per-write for
the bindings you observe and nothing for the rest; an `unobserved:` block opts a
hot region back out.
