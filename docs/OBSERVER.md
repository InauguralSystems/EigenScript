# The Observer

> This is the long answer — the model underneath EigenScript's six
> interrogatives (`what`, `who`, `when`, `where`, `why`, `how`), the
> trajectory words (`converged`, `improving`, …), and the
> feature; the [README](../README.md#ask-your-code) is enough for that.
> Read this if you want to know what the words actually mean — and why
> they sometimes disagree with your intuition.

## The signal and its conventions

The observer records a binding's assignments and answers questions about
that history. Numeric bindings use their value and displacement. Other
bindings retain entropy diagnostics and bounded content snapshots. The
numeric predicates use cited standard tests where those exist; a finite
window remains an approximation to questions about an infinite sequence.

Numeric `improving` adopts the loss convention that lower is better, with
Keras' running best and patience. This is an explicit convention, rather
than something inferred from entropy or from an external target. A
smaller loss need not be a correct answer; check a solver's residual when
the destination matters. [PREDICATES.md](PREDICATES.md) gives the formulas,
citations, registered deviations and residual disagreements.

## What the observer knows

| You ask | Numeric binding | Non-numeric binding |
|---|---|---|
| `what is x` | current value | current value / content query |
| `who is x` | binding name (or type) | binding name (or type) |
| `when is x` | assignment count | assignment count |
| `where is x` | current value, preserving exact ints | current entropy |
| `why is x` | last raw displacement Δv; null before a step | last assignment's entropy change dH |
| `how is x` | `dh_zero / (dh_zero + \|r\|)` for a finite step; null before a step | entropy-step settledness `1 − min(1, \|dH\| / dh_zero)` |

**A binding's creation is its first observation:** the first local
assignment, or a parameter's call-time binding. Each later assignment in
the same activation adds one. `when` includes assignments made inside
`unobserved:`. A parameter's creation is not a tape `A` record.

For a numeric step, `r = Δv / max(|v|, |v_prev|, scale)` with
`scale = 0.001` and `dh_zero = 0.001`. If both operands are ints and checked
subtraction fits int64, `why` is an exact int. Otherwise subtraction uses
a double. The following cases define the whole numeric surface:

| last step | `why` | `how` |
|---|---|---|
| none yet (one value) | `null` | `null` |
| finite → finite, finite r | Δv | `dh_zero / (dh_zero + \|r\|)` |
| finite → finite, subtraction overflows | signed infinity | `0.0` |
| finite → ±inf, or ±inf → finite | signed infinity | `0.0` |
| infinity → same-sign infinity | `nan` | `nan` |
| infinity → opposite-sign infinity | signed infinity | `0.0` |
| from or to NaN | `nan` | `nan` |

Fixed points of numeric `how` are:

| \|r\| | `how` |
|---|---|
| 0 | `1.0` |
| `dh_zero = 0.001` | `0.5` |
| `dh_small = 0.01` | `0.09090909090909091` |
| 0.005 | `0.16666666666666666` |
| 0.05 | `0.0196078431372549` |
| 2 | `0.0004997501249375313` |

The `at L` and `when N` forms read the same triple from the assignment's
history snapshot. The snapshot also retains D2's `best` and `since`, so a
past query sees that moment's running-best state.

**Non-numeric entropy is unchanged.** It is recomputed from current
contents when queried, so in-place mutation is visible in `where`.
Assignment-time `why` does not move on mutation or on a query. Strings use
character entropy; lists and dicts combine scalar leaves with a size term.
The entropy walk stops at a container reference: a nested container
contributes its size term rather than a recursive walk. A number inside a
container still contributes its numeric entropy. Bools keep their entropy
route; they are not numbers. Numeric bindings themselves neither compute
nor store entropy.

### What carries a trajectory

Everything above is keyed to an **environment slot** (`env_obs_slot`) — the
Value carries no observer state. A binding has a history; a container
element does not (#1048):

| carries a trajectory | does not |
|---|---|
| a named local; a closure-captured local (one factory call per entity); an `eval`-generated name | a dict field `ch.a`; a list element `xs[0]`; a function parameter; a `for` binder; a `for`-body `local` at module level (cleared each iteration) |

And one binding rebound from a *different* element each iteration
(`loop while i < n: local q is fleet[i][2]`) carries the interleave of all of
them — a verdict about nothing. Lint `W024` flags that shape; the full table,
the module-level-`for` asymmetry and the closure-per-entity recipe are in
[PREDICATES, What carries a trajectory](PREDICATES.md#what-carries-a-trajectory).

## The oracle: where names come from

The observer's experience is a smooth, continuous signal. Turning that
into the vocabulary `converged` / `stable` / `improving` / … requires
drawing lines on it — and a line is a decision made from outside. The runtime
uses fixed thresholds (`dh_zero = 0.001`, `dh_small = 0.01`,
`h_low = 0.1`), a fixed ten-step window (eleven numeric values), and a value-channel characteristic
scale of `0.001`.

```eigenscript fragment
dh_zero is 0.001
dh_small is 0.01
h_low is 0.1
scale is 0.001
window is 10
```

These are runtime constants. `get_observer_thresholds` still returns
`[dh_zero, dh_small, h_low]` in R3.1; `h_low = 0.1` belongs to the
non-numeric entropy rules. The numeric tests adopt the documented loss
convention and tolerance bands.

## The trajectory vocabulary

`report of x` and the bare predicates (`converged`, `improving`, …) route
by the binding's current type. **Numeric bindings use the value channel**: it
classifies relative steps `Δv / max(|v|, |v_prev|, scale)` and retained raw
steps. **Non-numeric `report` and four predicates use the entropy channel**:
it classifies changes in `entropy(value)` against the entropy thresholds.
`converged` and ordinarily `stable` compare bounded assignment snapshots;
the non-reflexive buffer exception below gives `stable` its entropy rule.
The resulting vocabulary
is `converged`, `equilibrium`, `stable`, `oscillating`, `improving`, and
`diverging`; `report` can additionally answer `moving` when no band matches and
`undefined` at a current numeric NaN.
See [PREDICATES](PREDICATES.md#which-channel-answers-861) for the precise
windowed tests on each channel.

- **`opaque`** (#708) — the binding currently holds a function or
  builtin. A function has no content the observer can sample, so no band
  can honestly be claimed: `report`/`report_value` answer `opaque` and
  every predicate is false. This is a statement about the observer's
  coverage, not the value's motion — the same visible-gap rule as
  `moving`.

### Reserved report forms

`report` and `report_value` are reserved words, never binding names or
first-class functions. Use `report of x` / `report_value of x` with a named
variable; parentheses around that name are allowed. Any binding of either word,
or a non-identifier operand (literal, arithmetic, call, index, field, or argument
list), is rejected at compile time with `E005`. Assign an expression to a
variable first so there is a binding history to inspect. Dict fields such as
`d.report` remain legal. See [SPEC](SPEC.md#observer-semantics-and-predicates) for the language rule.

### Two signals: entropy vs. value (`report` vs. `report_value`)

Numeric `report`, `report_value` and predicates share the value channel.
`converged` is STD's windowed Cauchy test; `stable` is D1's 1% midrange
ball; `improving` is D2's running lower best with a relative significant
improvement and ten-step patience. The incumbent oscillation, divergence
and equilibrium tests retain the relative and raw step signals. An
all-exact int64 window uses zero raw noise floor and absolute settled
thresholds. [PREDICATES.md](PREDICATES.md#which-channel-answers-861) gives
the exact formulas and the differences between these tests and their
infinite-sequence questions.

A numeric trajectory snapshot carries `rel`, `raw`, `exact`, `best`,
`since`, and an exact `last_value`. Its `dh` is empty and its `entropy`,
`dH` and `last_entropy` fields are null. `classify of t` rebuilds this
state. `classify of [t, "entropy"]` on that snapshot raises `value`;
there is no numeric entropy history to classify.

For non-numeric bindings, `report` and four predicates retain entropy.
`converged` and ordinarily `stable` instead compare detached assignment
snapshots across a full window, bounded to 4,096 content units. Mutation
through an alias remains visible on reassignment. An oversized or refused
snapshot clears eligibility until a fresh full bounded comparison window.
An accepted snapshot containing NaN, including a buffer cell, is unequal to
itself under raw IEEE equality: `converged` stays false and `stable` uses
its entropy-window rule after a full bounded comparison window (S10-D1).
This preserves the matmul scenario's `false`, `true`, `false` result for
`x == x`, `stable of x`, and `converged of x`, without changing cells or
math flags. Observer equality is non-raising: a bool/number pair is unequal.
A function nested in a container is refused; retaining a closure in an
invisible observer edge would alter ownership.

The incumbent raw-step tests (#422/#674/#1891) recognize non-vanishing
same-sign or alternating motion even below the relative deadband. They
keep their floating noise floor; all-exact int64 windows use zero instead.
The ten-step half-window comparison still cannot separate every slowly
modulated decay from a runaway. Those measured residuals remain in
[PREDICATES.md](PREDICATES.md), alongside R3-STD's slow-drift limitations.

### Graded against mathematics (`make observer-oracle`, #1746)

`make observer-oracle` scores the six predicates against `tools/observer_oracle/corpus.json`, whose properties are certified
offline (`certify.py`, sympy, on the values the runtime is fed; the generated values may refute a verdict, never prove one)
and turned into labels by `derive.py` from the definitions decided on #1754 (Hardy, NIST, Keras, settling time; each one's
provenance is in [`docs/PREDICATES.md`](PREDICATES.md)). Each predicate is scored against ONE question, so the headline
counts each verdict once: `converged`, `stable` and `improving` against a CONVENTION (settled within ε, or within a band,
from checkpoint n on; a new best inside the window, for an eventually bounded sequence), `oscillating`, `diverging` and
`equilibrium` against MATH (Hardy §§60, 62; weak stationarity, NIST 6.4.4.2). At a checkpoint whose value is NaN every
predicate answers the #1758 NaN convention instead: false, labelled CONVENTION. MATH "has a limit" is reported beside
`converged`, not scored: it is a whole-sequence property that no windowed observer can decide at n, and scoring the one
`converged` reading against both questions contradicted itself on 28 of 84 checkpoints, so even a perfect observer failed.
The MATH questions that stay scored are whole-sequence properties too, which a window can only approximate, and none is
scored at a checkpoint before its row's law last changes (each row declares that `regime` index; a law change is spelled
`step(n, <integer>)` or the row is refused): a MATH verdict read there would be decided by values after the read, so it is
reported, not scored.

Every row runs as module-level straight-line code under the interpreter, where `x` is a name (`OBSERVE_ASSIGN`,
`PREDICATE_NAME`), and as a `loop while true` form in three tiers (`EIGS_JIT_OFF=1`, the default JIT after 50 warm-up
calls, `EIGS_JIT_OSR_THRESHOLD=1`), where `x` is a function local in a slot (`OBSERVE_ASSIGN_LOCAL`, `PREDICATE_SLOT`).
Every run's `EIGS_DUMP_BC` listing must show the path its arm grades, and each run gets only its own tier's `EIGS_*`
variables (inherited ones are scrubbed). A reading that differs between arms, a REPORTED one included, fails the run. Each
JIT-tier run witnesses its own tier from `EIGS_JIT_HOT` and `EIGS_DUMP_BC`. In the jit tier the function thunk's last exit
lies past the loop's back-edge and `bked` is 0, so every iteration ran natively, `x_0`'s assignment included. In the osr
tier only the OSR thunk's last exit is recorded, so the witness covers the last iteration's body: OSR compiles at the first
back-edge, so `x_0` is always assigned interpreted, and an earlier iteration that bailed goes unwitnessed until #1768. A run
whose body stops computing `x` on an inf, NaN or clamped value (the JIT's designed bail) is reported as interpreted and
passes, so its readings grade the interpreter's observer for those iterations. The non-capability floor uses float
scaffolding and float recurrence operands, preserving its binary64 inputs and native witnesses after integer literals
arrive. Exact int64 capability rows retain int literals; until the R5 int fast paths, their JIT-enabled arms may instead
report an interpreted int-opcode refusal, requiring `INT_*` before observing `x`, no function thunk, and either no OSR
thunk or its recorded prefix exit exactly at that int opcode. Their readings remain scored in every arm. Every other run that does not witness fails as vacuous, and both
native tiers must still witness a body. The predicate READS never run natively: the JIT compiles neither
`PREDICATE_SLOT` nor `PREDICATE_NAME`.

A row's capability is derived from its values (IEEE inf/-inf/NaN; an int a double cannot hold exactly). Such a row runs
only on a binary whose probe shows the capability (one probe checks that `1e308 * 10` overflows to inf AND that inf × 0 is
NaN; a binary that does one without the other is refused), skips are printed, `EXPECT=ieee,int64` makes an absent one
fail, and every verdict on them must be right, or be declared wrong: Phase 2 passes `--declared
tests/phase2/oracle_expect.txt` (#1830), whose rows name an arm, a `row@checkpoint` and a predicate with the round
that fixes it. An undeclared wrong verdict fails, so does a declaration whose verdict is right now or was not examined,
and the integration merge (#1776) requires that file empty. By default the run also applies the committed floor,
`tools/observer_oracle/floor.json` (#1764): it fails when it gets wrong any verdict the v0.46.0 tag got right. An empty
`FLOOR=`, on the command line or in the environment, skips the floor. Its anchor is the binary
`tools/observer_oracle/build_anchor.sh` builds from the tag into
`${XDG_CACHE_HOME:-~/.cache}/eigs-oracle-anchor/<sha256 of the recipe>/`, under a lock. `make observer-oracle` first builds
it as `make observer-anchor` does: the recipe runs under `env -i`, and it reuses an anchor that is already there. The anchor's identity is the recipe plus the verdict
list, which every `--floor` run re-measures on it; its sha256 is recorded only as information, so the floor holds on any
toolchain whose build of the tag gives the same verdicts. There are no waivers: a floor verdict agrees with its label, so
losing it is wrong unless the label is, and a wrong label is fixed through `derive.py`/`certify.py`. The reference model
shares the observer's window and tolerances, so its agreement on window-limited rows is correlated, not independent
evidence.

CI runs the floor as the required check `observer oracle (floor)` (#1778), so a change that loses a floor verdict cannot
merge. The check runs `tools/observer_oracle/ci_lane.sh` on every code change, on every merge-queue candidate and on every
push to `main`. It is gated like the differentials, so a docs-only pull request skips it. The job builds its own anchor
from the tag. It calls `score.py` directly, so exit 1 means a verdict was lost and exit 2 a harness error. The proof that
the floor can still fail is a gate self-test: the `tools/selftests.txt` row `plants.py --selftest`, which runs when
`tools/observer_oracle/` changes. It reverses one floor reading per predicate, class and label direction, in every arm,
through the wrapper observer. Exactly those readings' verdicts must be reported lost. The arms still agree, so no FINDING
fires and only the floor can turn that run red.

## Resolution and limits

Numeric `where` is the value itself: there is no entropy ridge at unity on
this route. A constant at 1.0 can certify convergence, and decreasing loss
can improve on either side of 1.0. Entropy's magnitude symmetries remain
relevant to non-numeric containers and their scalar leaves, where that
measurement is still used.

Numeric `converged` asks whether eleven recent values fit the Cauchy
tolerance; `stable` asks whether they fit a 1% midrange ball. Neither can
look beyond the current window. A slow unbounded sequence can fit either
band, and a slow convergent sequence can certify with a substantial tail
remaining. The harmonic series and sublinear tails are documented residuals,
not proofs of convergence. Exact integer displacement prevents magnitude
from hiding a moving exact-int counter; mixed and float windows retain the
floating boundary scheduled for R3.3.

The window measures assignments, not time. Observe at a cadence that
resolves the dynamics of interest. `unobserved:` still records every numeric
sample, so wrapping substeps in it does not change numeric cadence.
`how` measures only the latest relative displacement. It can be 1.0 after a
pause even when the full window cannot certify convergence.

The numeric `improving` convention means a significant lower running best
within ten steps, subject to the finite-window and boundedness approximation.
A higher value can therefore still read `improving` after a recent lower
best. Conversely, a falling value that has not beaten its earlier best by
`min_delta` need not improve. This is the cited Keras convention, not a
claim that the program's objective has been met.

## Contracts: convergence as an assertion

A static type proves *shape* — `num`, `list`, `str`. It cannot state *"this
solver converges"* or *"this residual shrinks without oscillating."* Those are
properties of a **trajectory**, and the observer already classifies them on
every assignment, without you writing the check. `lib/contract.eigs` turns that classification into a
machine-checked assertion — the affirmative answer to "what replaces static
types here."

```eigenscript fragment
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
| `expect_regime of [trajectory of x, expected, msg]` | a caller-built history reads as `expected` | value |

Three things the observer's own semantics force on the design — and each is the
point, not an accident:

- **A trajectory crosses a call boundary as a *snapshot*, never as the value.**
  The observer's history lives in the binding slot it was written to (binding
  identity), so a value handed to a function arrives as a fresh, single-sample
  slot — its past does not travel. Two contract forms follow: the *drive* form
  (a seed + one-arg `step_fn`, applied into the contract's own local slot) when
  the contract should control the observation budget, and the *snapshot* form
  ([#421](https://github.com/InauguralSystems/EigenScript/issues/421)):
  `trajectory of x` captures the binding's observer windows into a plain,
  inspectable dict that does survive the call, and `classify of t` (or
  `classify of [t, "entropy"]` for a non-numeric entropy snapshot) classifies it with the
  same machinery `report_value` / `report` use. `classify` of anything that is
  not a snapshot raises `type_mismatch` — a bare value silently classifying as
  "no trajectory" is exactly the hole the snapshot exists to close.

- **Convergence is detected on the value channel — now by every surface
  (#861).** A monotonically *exploding* value has falling-then-flat
  entropy, so the old entropy-routed `report` labeled a runaway solver
  `converged` (measured: `grow` = `x*1.5` for 40 steps). Since #861
  `report` and the predicate words route numerics to the value channel,
  so the same run reads `diverging` on every surface — the distinction
  this bullet used to warn about is now enforced by the runtime rather
  than left to the caller's channel choice.

- **Contract-convergence means "inside the windowed Cauchy tolerance"
  (`dh_zero`, default `1e-3` relative with an absolute floor), not arbitrary
  precision.** Newton reaches machine-epsilon
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

The resolution floor the contracts once inherited —
[#422](https://github.com/InauguralSystems/EigenScript/issues/422), where
additive runaway read `converged` and sub-deadband oscillation read `stable` —
is closed by the raw-step signal
([above](#two-signals-entropy-vs-value-report-vs-report_value)): those now
classify `diverging` and `oscillating`, `expect_converging` fails *fast* on a
mid-run `diverging`, and `invariant_stable` throws on it. What remains true:
a drift whose steps *decay* settles by design, and convergence is still not
correctness — pin the destination with `ensure` on the final residual. (The
gap was filed upstream and fixed in the instrument rather than papered over in
`.eigs` — the forcing-function model working as intended.)

## Assignment sampling and history

Numeric samples are recorded on every assignment while the observer gate
is open, including assignments inside `unobserved:`. The value windows,
exact flags, `best`/`since`, and numeric interrogation snapshots stay
complete. `observe of x` returns `[band, where, why, previous why]`.
Non-numeric entropy and equality bookkeeping can be elided by the block.
The bare last-observed alias is not repointed by elided scratch assignments.
A predicate queried inside a block still raises.

The bare observer-loop stall backstop counts a numeric iteration as quiet
when `\|r\| < dh_zero`; it uses entropy change for a non-numeric binding.
A SIGUSR1 observer dump likewise prints a numeric binding's value and last
raw displacement, rather than entropy.

## Cost

With the observer gate open, numeric assignments perform O(1) value
bookkeeping and do not compute numeric entropy or dH. Two `log2` calls and
entropy-difference bookkeeping leave that path in R3.1. Relative and raw
rings plus exact flags are allocated when steps require them; D2's `best`
and `since` are scalars on the binding's slot. Numeric queries scan a fixed
ten-step window. Hosted cost measurements determine the change on the
observed-loop rows; R3.1 does not change cost bounds.

Non-numeric entropy retains its existing cost: scalar/buffer/text-builder
measurements are O(1), while lists and dicts cost their own element count.
Nested containers contribute a size term rather than a recursive entropy
walk. Equality snapshots add their separately bounded work. `unobserved:`
elides that non-numeric bookkeeping. The automatic gate below can skip
observer work for a whole program that has no reader.

### The automatic opt-out — the observer gate (#915/#972)

The automatic gate is shipped: the runtime skips the emission automatically when a
program provably never reads observer state. On a consumer that uses no observer
features it is worth **8.5x** (EigenMiniSat 4x4 Tseitin, 293 s -> 34 s, n=5 per
arm interleaved with the solver's counters identical). See "Using the gate"
below for the controls.

The reason the rest of this section is written so carefully is that the failure
mode is silent and total. If any opcode
that reads observer state is missing from the scan that decides "is anything
reading?", a program gates its own bookkeeping off and then reads slots nobody
updated — every binding answers `equilibrium` forever, with no crash and no
failing test.

Completeness therefore has to be pinned against the opcode set, and it **cannot
be derived from the C**. Five derivations were tried on #972 and all five gave a
confident wrong answer, in both directions: greps of the read-side API and even
`objdump -dr` relocations both miss `obs_stall_trajectory()`, which reads
`s->dH` / `s->entropy` as struct fields and calls no `observer_slot_*` function
and emits no symbol reference; a scan for struct-field reads false-positives on
unrelated `->n` reads; and a handler scan written against `case OP_X:` matches
nothing at all (the VM dispatches through `CASE(NAME)` computed-goto macros)
while the same scan repaired to `CASE(X)` matches everything, including a scope
marker and a writer.

So every entry in the `OpCode` enum in `src/vm.h` carries a hand-recorded
marker instead:

| marker | meaning |
|---|---|
| `obs:READS` | answers **from** recorded observer/temporal state — the set the liveness scan consumes |
| `obs:WRITES` | records, updates, resets or stamps that state |
| `obs:DIAG` | reaches it only through the SIGUSR1 diagnostic dump, never through program-visible semantics |
| `obs:NONE` | none of the above |

`tools/obs_marker_check.sh` enumerates the enum and goes red on any opcode with
no marker, so a new opcode is a red line at the moment it is added — which is
when its author knows the answer and nobody else ever will. The gate proves a
verdict was *recorded*; it cannot prove the verdict is *right*, and it stops at
the opcode's own handler (`OP_CALL`, the JIT's OSR entry, and assembled chunks
are excluded by name, each with the mechanism that covers it instead).

Two results from that reading are worth knowing before touching this area, both
contrary to the opcode names: `OP_OBSERVE_ASSIGN` is a **no-op** (the slot model
observes at `OP_OBSERVE_NAME_POST` after the SET), and the bare `OP_INTERROGATE`
reads **no** observer state at all — `when` / `where` / `why` / `how` on a value
operand return constants, because observer state is binding-keyed and a bare
value has no binding.

**What "pays nothing" means at the instruction level (#972).** The gate is
decided at compile time but *tested* at run time, because it can open mid-run
(a runtime arming, a SIGUSR1 dump, a descriptor). Where that test sits
matters: until #972's last residual was closed, `OBSERVE_ASSIGN_LOCAL` and
`OBSERVE_NAME_POST` still dispatched into their helpers — a call, the TOS
decode, the slot or name resolution (a hash lookup for a module-level name) —
and only *then* returned at `observer_slot_update_num`'s gate test, which
measured as +18% (module level) / +14% (function level, JIT) over
`unobserved:` on a 20M-iteration read-free loop. The test is now the first
thing both opcodes do, in the interpreter `CASE` bodies and inlined into the
JIT thunk ahead of the helper call (`emit_obs_gate_test`, src/jit.c — the
same two loads `eigs_obs_gate_open()` makes, through the VM's owner
back-pointer so nothing is baked but the trace flag's address), and the JIT
no longer emits a call for the no-op `OP_OBSERVE_ASSIGN` at all. With the gate
closed a read-free program's assignment therefore costs the two flag loads and
a branch; with it open nothing changes. The `observe-calls` tally is the
regression instrument: suite section [99u] pins it at `0` for a read-free loop
on both the interpreter and a witnessed JIT thunk, and at `populated` with a
reader or `EIGS_OBS_FORCE=1`.

**And what is left is not the observer — measured, with the control.** After
the hoist, a read-free module-level loop is still slower than the same loop
wrapped in `unobserved:`, and it is tempting to read that as observer cost
still leaking. It is not. `unobserved:` does a *second* thing at module scope:
#871 Part B promotes the names a block writes to module SLOTS when escape
analysis says nothing outside the block reads them, which replaces a hashed
`SET_NAME` with a slot store. The control that separates the two is the same
`unobserved:` program with its `print` moved OUTSIDE the block, so the
promotion is refused and the binding stays a module name (20M iterations, user
+sys CPU, n=5 medians, one shared box):

| module-level probe | v0.43.0 | pre-hoist | post-hoist |
|---|---|---|---|
| read-free, `x` a module NAME | 4.13 s | 4.12 s | **3.88 s** |
| `unobserved:`, `x` promoted to a module SLOT | 3.41 s | 3.42 s | 3.37 s |
| `unobserved:`, promotion refused, `x` a NAME | 3.91 s | 3.90 s | 3.95 s |

Against the like-for-like row the read-free arm went from +5.6% to −1.8%: the
observer residual is gone. The ~15% that remains against the promoted row is
the slot promotion, and it is available to any binding a slot can hold — it is
a scope-and-storage result, not an observer one. Inside a function, where
locals are already slots, the read-free arm is at or just under the
`unobserved:` one (2.85 s vs 2.93 s post-hoist; 2.94 s vs 2.96 s before it). Quoting
the raw `unobserved:`-vs-plain gap as "what the observer costs" over-attributes
it by roughly three-quarters.

## Using the gate

The gate is automatic and needs no source change. A program that never reads
observer state pays nothing for it; a program that does is unaffected.

| control | effect |
|---|---|
| `EIGS_OBS_FORCE=1` | force observer recording ON, whatever the scan decided. The escape hatch, and the baseline arm for any measurement — one byte-identical binary serves both arms. |
| `EIGS_OBS_GATE_STATS=1` | print one `obs-gate: observed\|unobserved <unit>` line per compiled unit on stderr, and at exit one `obs-gate: observe-calls N` line: how many times an observer update/sample entry point was *entered* (counted before its own gate test). A read-free program must report `0` — the observe ops skip the helper call outright when the gate is closed (#972, below), and the per-unit verdict alone cannot tell "skipped" from "called and returned at the gate". |

Both follow the tree's flag convention: any non-empty value that does not
start with `0` turns the control on, so `=0` and `=` leave it off.

### What arms the gate — the rule, precisely

The decision is made once per compiled unit, in `compile_ast`, and is
monotonic per interpreter state: once any unit arms it, every later unit in
that state records. A unit arms the gate when **any** of the following holds;
otherwise it does not, and nothing else does.

1. **A reader opcode** anywhere in the unit, including in functions that are
   never called: the interrogatives (`report of x`, `report_value`,
   `trajectory of x`, `where is x`, ...), a predicate (`converged`,
   `diverging of x`, ...), an observer-conditioned loop. The set is
   `opcode_is_observer_reader()` in `src/chunk.c`, pinned against the
   `obs:READS` markers by `tools/obs_reader_sync_check.sh`.
2. **A binding-load of an observer builtin's name** — `OP_GET_NAME` whose
   operand is `observe`, `classify`, `state_at`, `get_observer_thresholds`,
   `eval` or `record_history` (`report`, `report_value` and `trajectory` are
   listed for symmetry but cannot be loaded as values). This is the aliased
   form: `local r is observe` then `r of x` emits no reader opcode. `eval`
   and `record_history` are here because they open the channel at run time
   from a string or a call, so their presence is the only signal.
   **String data never arms** (#1046): `msg is "report"`, a keyword table
   `["converged", "report", ...]`, a dict key `{"observe": 1}`, a printed
   literal are all `OP_CONST` and are not consulted; neither is a field
   access spelled like a builtin (`tbl.eval` is a `DOT_GET` on a user value)
   nor a user `define observe(...)` (a binder). Until v0.43.0 the scan matched
   the whole constant pool, so the string forms cost a program its gate.
3. **A literal load target the unit cannot clear.** `load_file of "<literal>"`
   and `import NAME` are resolved *at the importer's compile time* with the
   same resolver the runtime uses (`resolve_eigenscript_file_from` and
   `eigs_import_resolve` respectively — project-first, then stdlib, anchored
   at the containing file's directory and the `eigs.json` project root), then
   token-scanned by rules 1-3 transitively. The unit arms if any module
   it reaches would, or if a target cannot be resolved, cannot be read, is
   not a regular file, exceeds the speculative budget, or nests past the
   depth cap. Until v0.43.0 the *presence* of an `import` armed the unit
   unconditionally (`+49..84%` for one unused `import linalg`); the import
   half of #915 is closed by #1046.
4. **A non-literal load** — `load_file of (computed)`, an alias of
   `load_file`, an `import` served by an embedder's source provider — makes
   the unit opaque and arms it.
5. **A forced or unknowable context**: `EIGS_OBS_FORCE=1`; a chunk assembled
   from a descriptor rather than compiled; the REPL, where line N+1 can read a
   binding from line N; more than one live thread during the eager pass.

The two literal loaders carry the same run-time guard: if the module compiled
at the load or import reads observer state and the gate was closed while the
program's earlier assignments ran, the load raises (see the next section)
rather than answering a rest value. A module scanned clean at compile time
and rewritten before it runs is the case that guard exists for.

### When the gate refuses instead of answering

The gate decides at COMPILE time, and a few constructs can make that decision
stale at RUN time. Where the runtime can prove the decision was wrong, it raises
rather than answering — the recorded history of bindings already assigned cannot
be reconstructed, so a late discovery is not recoverable and a quiet rest value
would be a wrong answer with nothing to fail on.

```
load_file: 'x.eigs' reads observer state, but the observer gate was closed when
this program's earlier assignments ran — they have no recorded history...
```

(`import` raises the same way, naming the module.) You will see this if a
program **rewrites a module between the compile and the load**, or creates a
nearer file that **shadows** the one the compile-time scan resolved. Both
loaders search the containing file's directory, the
`eigs_modules` walk, the nearest `eigs.json` project root, then the executable
and HOME stdlib roots (absolute paths are used as-is). For example, a newly
created sibling can replace a project-root or stdlib target. Changing the
process working directory does not redirect a file's loads. The failure is
that the file the gate inspected is not the file that ran; see the
[shared resolution chain](SPEC.md#modules).

Re-run with `EIGS_OBS_FORCE=1` to disable the gate for that program. That is
always safe — it restores the pre-gate behaviour exactly.

### When the gate declines to look

To decide before the program runs, the gate token-scans literally-loaded and
literally-imported modules itself — including ones reached only from a
function that is never called, since a `load_file` or `import` inside an
uncalled function still contributes to the answer. Before #1873 each target
was fully tokenized **and parsed** at import, so an optional module paid its
complete parse cost even when its function was never called. It now costs one
bounded lexical pass. Ordinary string and f-string literal segments are data;
f-string interpolation boundaries come from the real lexer's boundary
predicate, and their contents are scanned as code. Observer-reader names arm
the gate, and nested literal targets are followed;
the AST is built only if the load later executes. Measure the deterministic
import cost with `valgrind --tool=cachegrind --cache-sim=no --branch-sim=no
--cachegrind-out-file=out.cg src/eigenscript program.eigs`, then read the
`PROGRAM TOTALS` Ir row from `cg_annotate --auto=no out.cg`.

That
work is speculative, so it is bounded: a per-thread cumulative ceiling on how
many bytes the pass may read on the program's behalf, plus a rejection of
anything that is not a regular file (a FIFO target once hung the compiler
indefinitely, before `vm_execute`, with nothing printed).

When the ceiling is spent the pass stops looking and the gate stays **open** —
the conservative answer. Nothing is silently wrong; the program simply pays for
observer bookkeeping it may not need. `EIGS_OBS_GATE_STATS=1` shows this as
`observed` lines on a program you expected to gate closed.

The ceiling is picked against the real population rather than chosen round: the
largest transitive module tree in `lib/` is `ui.eigs` at 287 KiB across 19
units, the next largest is 69 KiB, and the budget clears the largest by 3.5x.
A suite check pins that — if a stdlib tree grows past the budget, the check
fails and the number gets re-picked deliberately instead of the win quietly
disappearing.

Shared modules are charged once, not once per reference, and identity is the
file itself rather than the path spelling — the same module reached through a
relative path, an absolute one and a symlink is one charge, not three.

### Known residual

The native embedder instance of the #1027 family is closed by #1038: states
start with recording **open**, so a host that never compiles still records its
slot updates. The startup `eigs_obs_enable()` workaround is no longer required.
A descriptor (`vm_run_bytecode` / `sandbox_run`) reading an unrecorded binding
after a compiled host closed the gate raises through the #1027 guard; it cannot
recover the lost history. See the [embed observer contract](EMBEDDING.md#observer-contract-1038--1028)
for the default and the explicit #1028 eval opt-in. Default evals retain history
across calls; opted-in evals reject later observer-reading units conservatively
when an earlier unit ran unobserved. `EIGS_OBS_FORCE=1` from the start avoids
that gap. Retained compiled functions can keep the eval gate open.

Separately, every literally-loaded or literally-imported module is **read
twice** when it later executes — once by the gate's token pass, once for real
by `load_file` (no module cache by design) or by the first `import` (cached
thereafter). It is no longer parsed twice: the gate retains only its observer
verdict, and the runtime parse is the one that runs. The speculative budget
above bounds the first read.
