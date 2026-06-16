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
| `how is x`  | a stability reading | (see *Rough edges* — currently coarse) |

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
on `|x| = 1` is different — see *Rough edges*.

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

## Rough edges (current implementation)

Honest notes about where the code, as of this writing, does not yet fully
honor the model above. These are observations, not yet fixes.

- **The unity horizon is special-cased to zero.** `compute_entropy_impl`
  returns `0` for `|x|` exactly `0` or `1`. At `1` that is the *opposite*
  of the formula's limit there (which approaches the maximum). The
  defensible reading is that the ridge can be *approached* by motion but
  only *occupied* by direct assignment, so an exactly-placed `1` is marked
  as a boundary event. The practical effect: a value sitting at exactly
  `1.0` reports as `converged` immediately. Worth a deliberate decision:
  is unity the horizon (drop the special case) or a home point (re-center
  the formula)?

- **`how` is degenerate.** It computes `1 - entropy/last_entropy`, but the
  observer sets those two equal on every refresh, so `how` is effectively
  always `0` (or `1` when entropy is `0`). It does not currently provide
  the `0–1` gradient its name suggests. Treat it as not-yet-implemented.

- **Observation is lazy, so trajectories are sampled at *reads*, not
  assignments.** Assignment only marks the value dirty; `where`/`why` are
  computed when you ask. Between two interrogations only the latest value
  survives — `why` compares consecutive *observations*, not every write.
  Inside `loop while not converged` the predicate is read every iteration,
  so it does see each step; ad-hoc `why is x` compares to the last time you
  asked. This is the price of "zero cost until you ask," and it is the
  right price — just know it's the contract.

## Cost

Zero until you ask. Assignment marks the value dirty in O(1); `where` and
`why` are computed only when an interrogative or predicate reads them. An
`unobserved:` block skips even the dirty-marking. You never pay for a
question you don't ask.
