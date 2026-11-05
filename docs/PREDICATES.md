# Predicates

The bare predicate words — `converged`, `equilibrium`, `stable`,
`improving`, `diverging`, `oscillating` — and the `report of x` builtin
classify a value's recent trajectory into one of those bands (`report` adds
labels the predicates don't have: `moving` when none of the six is true,
`undefined` at a current NaN, and `opaque` for a callable — see [The `report` builtin](#the-report-builtin)).
Each
predicate also has a **named form**, `converged of x` (and so on), that
binds to a specific value rather than the last-observed one — the
preferred form, especially in a loop condition (see
[Convergence loops in practice](#convergence-loops-in-practice)). This file
is the spec: what each one means precisely, the windowed formula it
evaluates, a canonical `dH`-sequence trace, and the pointwise behavior it
replaces. ([`docs/OBSERVER.md`](OBSERVER.md) is the model; this is the
operational target the runtime enforces.)

These are **trajectory claims, not proofs about the future**. Numeric
`converged` tests the diameter of a full recent window; `stable` tests a 1%
ball about its midrange; `improving` uses a running lower best and a ten-step
patience, following Keras' loss convention. A noisy tick need not erase a
recent improvement. Non-numeric bindings retain the entropy and bounded
snapshot rules below. Prefer the named forms in code that assigns more than
one binding.

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

**NaN.** At a checkpoint whose current value is NaN, all six predicates
are false and `report`/`report_value` return `"undefined"`. This is #1758's
O2 convention, not a mathematical verdict about the whole sequence.

**Finite windows cannot establish the labelled future.** R3.1 implements
arm R3-STD: STD_converged, the registered STD′_stable (Deviation D1), and
Keras' running-best test (Deviation D2). The incumbent `oscillating`,
`diverging` and `equilibrium` tests remain, with the exact-int noise floor
and non-finite alignments described below. The per-predicate tables printed
by `make observer-oracle` measure the remaining disagreements.

### How Round 3 is judged (#1758)

Round 3 of Phase 2 rewrites the six numeric predicates. Its acceptance is
pre-registered on #1758 (comments 6430031838 and 6430139845, 2026-10-26;
rulings R30-1 to R30-4, 2026-11-03), and the instrument is in
`tools/observer_oracle/`:
- `standard.py` holds each predicate's standard test (STD, the primary arm;
  STD′ and STD″ are reported), the ruled deviation D2 for `improving`, and the
  trivial and persistence arms C0, C1 and PERSIST. Every test cites its source.
  `--selftest` runs the one-time textbook checks.
- `families.py` holds the 16 process families. `S_split` draws four of them as
  the calibration families H-cal (`hcal/`). The held-out set H1 is drawn at the
  reveal from a drand round (`seal.py` states the procedure).
- `judge.py` scores every arm by balanced accuracy, with a paired cluster
  bootstrap over rows, and evaluates the six decision rules mechanically.
  `python3 -I tools/observer_oracle/judge.py --calibration` prints the
  calibration table.

**Deviations from the pre-registration** (its own clause: recorded before the
reveal):

| # | registered | as built | reason |
|---|---|---|---|
| D1 | `stable`: STD = the 2% band, STD′ = the 1% band | R3's `stable` is STD′, reference.py's `stable` exactly (a ball of radius 1e-2·max(\|centre\|, 1e-3) about the midrange). The decision rules still compare against the registered STD | The labels use this band. The 2% band loses `alt_series_ln2@60 stable` (R30-3 item 1, R30-4 item 3) |
| D2 | `improving`: STD = min(newer half) < min(older half) − min_delta | arm D2: Keras EarlyStopping's running best over the history, with the registered relative min_delta. A non-finite best counts as no best yet; the arm is false while the window holds a non-finite value; x₀ is never an improvement | It is the cited standard itself. The half-window form loses `quasi_2@300 improving` (R30-3 item 1, R30-4 item 2) |
| D3 | calibration `corpus.json` sha256 `317531993699d714312a2799ae7d0321a8c370713d29dd631d8028033a9383b0` (dffac840, 71 rows) | sha256 `e3f5e94e97bd28972480977a5ff21173221e878ab784abc7f4ed5459bedfefe4` (72 rows) | The added row is `ieee_nan_recover` (#1765/#2036), which pre-dates Round 3 (R30-4 item 6) |
| D4 | REF = `reference.py` sha256 prefix `11de2a0191b25086` | sha256 `fa74d83f23422f5ddee9b30dc0f133417f98d9d8e7f9806151233d9e18ca1993` | A docstring change (#2139). R30-1 item 4's report-only amendment will move it again, as its own Deviation (R30-4 item 6) |
| D5 | control (c): a window-4 build loses ≥ 0.05 BA on `converged` against INC | (c1) the window-4 build must FAIL the decision table; (c2) margin resolution is shown by STD `converged` with its tolerance scaled (`judge.py --tol-converged`): ×100 is tried first, then ×0.01 | On the calibration labels a window-4 build certifies a settled tail earlier and gains BA (−0.059 [−0.135, 0.007] on H-cal), while rules 2 and 3 still reject it. A tolerance change does not depend on checkpoint timing. ×100 gained BA, so ×0.01 is the recorded arm (RULING R30I-1 item 1) |
| D6 | the labeller's NaN window for `converged`/`stable` is [n−9, n] (10 values) | [n−10, n], the observer's W + 1 = 11 values | The labels must ask about the window the observer holds. One label moves: `ieee_nan_recover@13 stable`, true → false. `floor.json` re-derived under the same anchor is byte-identical (RULING R30I-1 item 3) |
| D7 | rule 5: zero flips on the family-15 rows above the floor; family 15 copies 10 rows of the other families | rule 5 is evaluated only when every declared family-15 copy is compared (examined == declared > 0), else NOT EVALUATED and the table INCOMPLETE. Family 15 draws its 10 bases from the other H1 families' own generators and keeps only a base that stays ≥ 10 in magnitude over its whole run, so every ×1e-3 copy clears the 1e-2 floor (the bases are scored rows too) | Rule 5 printed PASS on zero comparisons, and on the frozen draws most H1 seeds had no base above the floor (12 of seeds 1–30 had none). A pool of existing rows held fewer than 10 such bases on 11 of seeds 1–500 (RULING R30I-2 item 1) |
| D8 | family 8: 4 parameter draws × 10 seeds, amplitudes {1e-9, 1e-5, 1e-3, 1e-1, 10} | the five draws are the five amplitudes, × 8 seeds (40 rows) | Four draws over five amplitudes never covered all five (RULING R30I-2 item 2) |
| D9 | the population is the rows every runtime arm runs | every row stays. A runtime arm without a row's capability (INC: int64, ieee) has no reading there. Rule 2 against INC is NOT EVALUATED on those rows (each comparison is paired on the rows both arms read, and the count left out is printed). Rules 1, 3 and 4 use all rows the subject reads; rule 6 remains the #1830 gate | Otherwise `f14_7`, #1830's own int64 row, left every arm's population because INC lacks int64 (RULING R30I-2 item 4) |
| D10 | arms are binaries | a runtime arm is pinned by recipe: the manifest records (source SHA, recipe id, binary sha256). `recipe_id` is the sha256 of the build recipe (`tools/observer_oracle/build_arm.sh`, or `build_anchor.sh` for the anchor), which builds a commit's own files with `make build`. Verification matches source SHA and recipe id; the binary sha256 is printed as information. An arm with no recipe stamp is pinned by its binary sha256 | The across-machine A/A cannot share binary hashes (another toolchain builds other bytes) (RULING R30I-3 item 3) |
| D11 | (not stated) | the subject must have every registered capability: a subject arm lacking int64 or ieee FAILS rule 6, and rules 1, 3 and 4 are NOT EVALUATED for it, with the reason printed | A subject that reads fewer rows must never be advantaged. Without this, a subject that lost int64 would never be scored on #1830's own row (RULING R30I-3 item 4) |
| D12 | R3-STD = each predicate's test replaced by STD_p; keyword, window and tape unchanged. | R3-STD computes STD_p's tests on the exact-aware signal (#1830's int path, decided per window): a window of all-exact int64 steps uses a noise floor of 0 in the raw tests and the absolute tolerance `rtol·scale` in the settled tests. | Rule 6 (#1830's declaration list empty) binds every subject arm including R3-STD, and STD_p on a float signal cannot satisfy it (int64 verdicts 12/18 against 18/18; an exactly incrementing counter is not converged). The signal is the measurement device; the test is unchanged (R30-2 item 3). Modelled effect: Two keys per predicate on the 72-row corpus: `int64_count`@10 and @60 × {`converged`, `stable`}, four keys total, R3 false and STD/D1 true. (RULING R31-1 item 2.) |

Under RULING R31-1 (2026-11-04), the R3-versus-STD/D1/D2 parity check is
per key: the differing set must be exactly those four D12 keys, each printed
with both verdicts, examined == declared == 4. A fifth or missing key fails.
Aggregate converged FP 6→4 / TN 118→120 and stable FP 14→12 / TN 102→104
are consistent with that set, while improving is identical; aggregate cells
are not the proof. The registered LOO arm "R3-STD without the int path" is
scored on H1 beside R3-STD, so the strict reading of the amendment has its
comparison. No decision rule changes. Frozen `standard.py`, `reference.py`,
the instrument and the labels are unchanged.

`judge.py --calibration` refuses to run on a `corpus.json` or `reference.py`
other than the D3 and D4 files. `judge.py --corpus DIR` refuses (exit 2) unless
`DIR/manifest.json` pins:
- the set's corpus, labels and certificate, and the row programs score.py runs
  for them;
- the measurement code, derived rather than listed: every file under `tools/`
  that `import judge, score, plants` loads in a fresh interpreter;
- every arm: a recipe arm by (source SHA, recipe id), with its executable equal
  to its own stamp's binary; an arm with no recipe by its binary. Each arm's
  stdlib tree (`lib/`) is pinned too.

(RULING R30I-2 item 5, R30I-3 items 2–3, R30I-4 items 3–4.) The manifest's own
sha256 is printed when it is sealed and when it is verified, and that number is
posted on #1758 at the commitment. `build_arm.sh` builds under `env -i`, as the
`observer-anchor` target does, so no caller's `MAKEFLAGS` or `CFLAGS` reaches an
arm.

The decision rules compare exact rationals (R30I-4 item 2): BA, FPR and their
differences are computed with `fractions.Fraction` from the confusion counts,
and a bootstrap CI bound enters a rule after rounding to 1e-9. So a value
exactly on a registered threshold (0.05, 0.02, 0.65) decides as the
pre-registration's text says. Floats remain for printing and for the bootstrap.

Two consequences of D7, recorded here (RULING R30I-3 item 8):
- Family 15's bases come only from families whose rows stay above |10|. In
  practice those are families 7, 8, 9, 10 and 13. The p-series, power laws,
  alternating runaways and #1891 rows start below 10, so rule 5 never sees a
  diverging or runaway row. That follows from the registered floor.
- The copies are regenerated from scaled parameters, so they are scalings
  within 2.4e-15 relative, not bit-exact copies of base × s.

## Which channel answers (#861)

The predicate words and `report` are **routed**: a binding whose most
recent observed assignment is **numeric** answers from the **value
channel** — the classifier below, over relative steps
`rel = Δv / max(|v|, |v_prev|, scale)` (#1045); every
other binding (strings, containers) uses deep equality of successive
assignment snapshots for **`converged`** and ordinarily **`stable`**: every
successive pair in the full window must be equal. Numeric cells compare
exactly across int/float kinds; a bool/number pair is simply unequal, without
raising. This makes finite content changes visible and lets an unchanged
non-empty value converge. The bounded NaN-containing snapshot exception below routes
`stable` to its entropy rule after a full bounded comparison window. The other
four predicates, and `report`, answer
from the **entropy channel**, the
windowed formulas in "The six predicates". `report_value of x` is the
value-channel classifier by name (identical to the routed words on a
numeric binding — the two surfaces cannot disagree); `classify of
[t, "entropy"]` reaches it only for a non-numeric snapshot. For a numeric
snapshot it raises `value`: numeric bindings no longer compute or store
entropy. Numeric `where`, `why` and `how` read the value channel; numbers
inside a container still contribute to that container's entropy.

Each equality entry compares against a private content snapshot, not a
reference that can be changed through an alias.  Snapshotting is bounded to
4,096 content units per assignment (value nodes plus string/key bytes, buffer
elements, and text-builder bytes). A larger value is **not sampled**: both
predicates refuse to judge (return false) and reset the equality run. Both
remain ineligible until a new full window of bounded comparisons is available.

An accepted snapshot containing a NaN float or buffer, directly or inside a list or
dict, is unequal to itself: buffer cells use raw IEEE equality without
normalizing data, raising or writing math flags. `converged` remains false.
For that bounded, non-reflexive snapshot only, after a full bounded comparison
window, `stable` uses the entropy-window formula below (S10-D1); it can be true
even though equality is false. This
preserves the bank's `false` / `true` / `false` result for the real matmul
scenario's `x == x`, `stable of x`, and `converged of x`. A current refused or
oversized snapshot gets no entropy fallback and clears its eligibility, even
when the entropy window is already complete. Finite snapshots keep the
comparison against detached contents, so mutating an aliased container before
assigning it again cannot manufacture equality.

The observer's additional comparison work is bounded independently of
container size; the pre-existing entropy calculation remains size-dependent.

Why: entropy is a function of `|x|` alone, so any clause on it is a
clause on magnitude. The current CI corpus compares every predicate, not
just `converged`, against its labelled question. Run
`python3 tools/observer_oracle/score.py src/eigenscript` and read its
**DOCUMENTATION TABLE** for the per-predicate incumbent, `REFERENCE`,
`REFERENCE_ENTROPY`, and constant-false scores. The command derives every
cell from the corpus and the selected binary; no score is copied into this
document. The explicit entropy channel can certify a geometric runaway and
can fail to certify a finite nonzero limit because magnitude is a lossy proxy
for motion. Entropy and dH are still computed and exposed for non-numeric
bindings. They do not decide equality-routed convergence or finite-snapshot
stability; they do decide stability for the bounded NaN-containing snapshot exception.

**The numeric definitions (R3.1, arm R3-STD).** The fixed window holds
`W = 10` steps and their `W + 1 = 11` values. Let `hi` and `lo` be its
maximum and minimum, `c = hi/2 + lo/2` its midrange, and `x` the current
value. The characteristic scale is `scale = 0.001`.

| band | fires when | source |
|---|---|---|
| `converged` | full finite window, `hi − lo ≤ 0.001·max(\|x\|, scale)` | `standard.py:std_converged`, `reference.py:converged`; Rudin, *Principles of Mathematical Analysis*, 3rd ed., Def. 3.8 / Thm. 3.11 (windowed Cauchy criterion) |
| `stable` | full finite window, `hi/2 − lo/2 ≤ 0.01·max(\|c\|, scale)` | D1, `standard.py:stdp_stable` = `reference.py:stable`; the registered 1% settling band (STD′), rather than STD's 2% band |
| `improving` | a significant new running lower best in the last `W` steps; finite current window; not `reference.py:diverging`, nor a full window with `reference.py:_expanding` | D2, `standard.py:d2_improving`; [Keras EarlyStopping, v3.6.0](https://github.com/keras-team/keras/blob/v3.6.0/keras/src/callbacks/early_stopping.py), `mode='min'`, running `best` and patience, with the registered relative `min_delta` |
| `diverging` | incumbent non-vanishing same-sign raw steps, or the infinity rule below | #422/#674/#1891, `obs_num_diverging` |
| `oscillating` | incumbent relative sign flips, non-vanishing raw alternation, or window-scale folding | #422/#1044, `obs_num_oscillating` |
| `equilibrium` | incumbent near-zero relative-step mean and variance, excluding raw oscillation and a one-direction raw trend | #1899, `obs_num_equilibrium` |

**D2's history.** The binding keeps `best` and `since` across the whole
numeric history, including samples inside `unobserved:`. A later value
improves only when `v < best − 0.001·max(\|best\|, scale)`; otherwise it
leaves `best` unchanged. Non-finite values never become `best`. The first
finite value establishes the baseline and is never itself an improvement.
A non-finite value anywhere in the current window suppresses `improving`.
The boundedness approximation rejects a reference-diverging window or a full
window whose fluctuations cross its mean at least twice and whose newer-half
maximum deviation exceeds its older half's. This is D2 exactly, including
(a) non-finite best means no best, (b) the finite-window veto, and (c) the
baseline rule. It does not require four samples or a full window to fire.

**Exact int64 steps.** When both values are ints and checked subtraction
fits int64, the displacement is exact and its ring entry is flagged exact.
An overflowing int difference, mixed int/float pair, or float pair uses a
double displacement. One shared per-window test decides whether every step
is exact. Such a window uses zero noise floor in the incumbent raw tests
and absolute tolerances in the settled tests: `1e-6` for `converged`, and
radius `1e-5` for `stable`. A moving exact-int counter therefore cannot
settle merely because its magnitude is large. A window containing even one
inexact step keeps the floating rules.

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

The three standard tests do not inherit the incumbent motion-band vetoes.
Their verdicts can overlap with a motion predicate; `report` keeps its
priority `oscillating → diverging → improving → converged → equilibrium →
stable → moving`. A true `converged` predicate can therefore coexist with
`report == "improving"`. `converged` implies `stable`; `equilibrium` retains
its separate raw-trend and raw-oscillation exclusions.

**The relative signal.** The observer records
`r = Δv / max(\|v\|, \|v_prev\|, scale)` alongside each raw displacement.
This remains the signal for the incumbent motion/equilibrium tests, numeric
`how`, and the stall backstop. The standard `converged` and `stable` tests
compare the window's value span, rather than testing each `r` separately.
Below the scale their floating tolerances become absolute. Exact-int
windows use the absolute tolerances regardless of magnitude.

**Documented residuals of R3-STD.** These are finite-window limitations,
not new acceptance exceptions:

- Sublinear tails settle before reaching the limit: the p-series with
  `p = 2` first certifies at `n = 82` with error `7.3 × eps`; `p = 1.5`
  at `257`, `47.6 × eps`; `1 + n^−0.5` at `286`, `59 × eps`.
- Harmonic sums first read `converged` at `n = 1295` (706 of 2001
  prefixes), and never read `diverging`. Harmonic sums with ±0.001 noise
  first certify at `1094` (1675 of 3000 prefixes). The harmonic stable
  band starts at `101` (1900 of 2001 prefixes). A finite Cauchy window
  cannot decide the infinite Cauchy condition.
- D1's stable false positives include the harmonic 300/2000, log 300,
  sqrt 300, inverse-log 300, power-law ML loss 2000 and sine-iteration 2000
  rows. The incumbent diverging test still misses harmonic 60/300/2000,
  log 300, sqrt 300, Hardy XXIV.5 and the upward sawtooth.
- A mixed window around an int counter can still use floating tolerances:
  the `int64_count` float at index 25 leaves `converged` and `stable` true
  through index 35; index 36 is the first all-exact window. Same-sign
  float ulp steps and the scale rule belong to R3.3.
- A one-step pause alone does not fill the convergence window. The
  `ieee_nan_recover@13 stable` label disagreement is a windowed-band
  residual: the NaN leaves at 14 and D1 first fires at 20; the NaN-free
  infinity-recovery twin first fires at 19.

- The bare-loop stall backstop can miss constant-amplitude cycles whose
  peaks do not fall in both halves of the retained window. At default
  W = 10 the recent half has five inputs; period-6 `[5, 1, -2, 3, -2, 1]`
  hangs on R3-STD, c8 and main. This is a Phase 3 candidate alongside the
  certified-verdict work (RULING R31-6).
- Still-contracting alternations keep their convergence route. From 1.0,
  multipliers -0.999 and -0.9999 take 14511 and 145089 iterations,
  respectively, with cost growing approximately as ln(scale)/ln|r| as r
  approaches -1. These are ruled costs, not a new predicate or stall rule.

`converged` is a stopping criterion, not proof of arrival or of a finite
limit. Pair it with a residual test when the destination matters.

## Inputs

The observer belongs to a binding's environment slot. Numeric assignments
record the current value, relative and raw step rings, an exact flag per
step, and D2's running `best`/`since`. Numeric `where` is the current value,
`why` is the last raw step, and `how` is
`dh_zero / (dh_zero + |r|)` for a finite step. Before any step, `why` and
`how` are null. See [OBSERVER.md](OBSERVER.md#what-the-observer-knows) for
non-finite cases and fixed points.

Non-numeric bindings retain current entropy, `dH`, previous `dH`, and an
entropy-step window, plus the bounded comparison snapshots described above.
`where` recomputes their entropy from the current contents at query time;
`why` records assignment-time change. Asking never writes observer state.

**`unobserved:` (#1049).** Numeric value records remain complete, including
exact flags, D2 state, the interrogation triple, and history snapshots. The
six named predicates, numeric `report`, `observe`, `trajectory`, and numeric
`where`/`why`/`how` therefore retain their answers after the block. A
predicate asked inside the block still raises. Non-numeric entropy and
comparison samples are elided, so their windows and verdicts can differ.
The last-observed alias is not moved by an elided assignment: scratch work
inside a block cannot hijack a bare `loop while not converged`.

A `null` seed declares a binding without a numeric sample; the first real
number is then the baseline. A numeric seed inside `unobserved:` still
counts as the first numeric observation.

```eigenscript fragment
define first_stable(values) as:
    tracker is null
    for v in values:
        tracker is v
        if stable of tracker:
            return v
    return null
```

For the entropy formulas below, `window` means the entropy-step ring,
oldest to newest; `count` is its number of real entries, at most `N`.

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

See "The relative signal" above for what it means.

Two derived window constants (for the fixed window depth `N = 10`):

```
VOTE  = 0.6                min fraction of genuine same-direction steps for improving/diverging
FLIPS = ceil(N / 3)  = 4   min sign-flips in the window for oscillating
```

## The window (#1044)

Numeric window tests read `N = 10` **steps**, spanning `N + 1` values —
assignments, not seconds. Entropy formulas read ten entropy steps. The depth is fixed by `OBSERVER_WINDOW_N`; a window
must be full before a quiet verdict such as `converged` can fire.

```eigenscript fragment
window is 10
```

**Time versus samples.** A mode slower than about ten samples of the consumer's
cadence cannot fold inside the window. Choose an observation cadence that puts
at least one period of the slowest mode inside those ten samples (`10 ≥ T / Δt`).
A mode much faster than the cadence can alias too, so sample fast enough to
preserve its reversals. The numeric route keeps relative and raw rings plus exact flags; and folding/variance tests are `O(10)` per
verdict asked, not per assignment.

## Configuration recorded on older tapes

Tape formats retain observer-configuration events so recordings made when the
configuration builtins existed still replay deterministically. Ordinary source
programs cannot emit those events now; live runs use the fixed thresholds,
ten-step window, and characteristic scale above.

## Partial windows

Numeric `converged`, `stable` and `equilibrium` require ten steps (eleven
values). The incumbent motion tests need enough steps for their structure
tests; D2 `improving` can fire as soon as a later finite value improves the
baseline. Infinity and NaN follow their rules regardless of window fill.
Non-numeric rest predicates need full windows; entropy motion predicates
retain their three-step minimum. `report` retains its partial-history
fallback; a single numeric baseline reports `equilibrium` while the six
predicates are false.

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

## Non-finite rule (R3.1)

Float overflow produces signed infinity; there is no finite saturation
ceiling. A held finite `1e308` can converge like any finite constant.

| current value | `oscillating` | `diverging` | other four predicates | `report` / `report_value` |
|---|---|---|---|---|
| NaN | false | false | false | `undefined` |
| ±inf, with the opposite-sign infinity in the window's `W + 1` values | true | false | false | `oscillating` |
| ±inf, without an opposite-sign infinity in that window | false | true | false | `diverging` |

These rules also apply on partial histories. A non-finite value still in a
finite-current window prevents STD convergence, D1 stability, and D2
improvement. The original runaway and finite-constant scenarios remain in
`tests/test_observer_saturation.eigs`.

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
except for equality-routed `converged` and ordinary `stable`; the bounded
NaN-buffer stability exception does use them. They also serve the explicit
`classify of [t, "entropy"]` channel for non-numeric snapshots only. `report_value of
x` (#294) is the value-channel classifier by name — on a numeric binding
it and the predicate words are one classifier and cannot disagree.


## The six predicates — the ENTROPY route

**These formulas classify the trajectory of `entropy(value)`. Since #861
they answer the four entropy-routed predicates and `report` for non-numeric
bindings (strings, containers), plus all six predicates on the explicit
non-numeric entropy channel; numeric bindings use the value-channel definitions above,
and routed non-numeric `converged`/`stable` use deep equality except for the
bounded NaN-buffer stability case described above.** The traces and design notes describe this retained entropy mechanism;
they do not define numeric predicates.

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

## Overlaps and report priority

On numeric bindings, STD convergence and D1 stability answer their standard
window questions independently of the incumbent raw-motion predicates.
D2 can remain true for ten steps after a significant lower best, including
steps that also certify convergence. These overlaps are intentional;
`report`'s ranking remains unchanged. Do not infer that every true predicate
must be the string returned by `report`.

`converged` implies `stable`. Numeric `equilibrium` additionally rejects a
one-direction raw trend (at least two nonzero raw steps of one sign; zeros
are neutral) and raw oscillation. Non-numeric predicates retain the
entropy/equality rules above, with their own overlaps. The six bands are
not exhaustive: `moving` names the remaining classified motion.

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

For numeric bindings these use the same helpers as the named predicates.
At a full window `report` names the highest-priority true predicate, or
`moving` if none is true. A true `converged` does not force the string
`converged` when a higher-priority motion predicate is also true. At a
current NaN the label is `undefined`; callable bindings are `opaque`.
Non-numeric `report` retains the entropy classifier, so it can differ from
the equality-routed `converged` and `stable` predicates.

The existing partial-history fallback is retained. A single numeric value
reports `equilibrium`, although no step has occurred and all six predicates
are false. Once steps exist, numeric motion tests, including D2, can answer
before the settled tests have a full window.

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

`sqrt(2)` settles to `1.41421…`; once the full window
fits the Cauchy tolerance it reports **`converged`** — the textbook example of
convergence is certifiable. (Before #861 the `entropy < h_low` clause
blocked every limit in `[~0.013, 76]`, and this section documented the
blindness as intended behavior: "it reports `equilibrium`, not
`converged`." See `tests/test_windowed_converged.eigs` WC4, now pinned to
the certification.)

### Short trajectories cannot certify convergence

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

### Probe expressions; do not probe by writing the subject

The named form fixes *which binding* is classified, but the observer still
records every assignment to that binding. For example, writing finite-
difference probes into `w` and then restoring it pollutes `w`'s trajectory:

```eigenscript fragment
w is 0.0
lr is 0.05
h is 1e-4
loss_at is (c) => (14.0 / 3.0) * (c - 2.0) * (c - 2.0)
steps is 0
loop while not converged of w:
    w is w + h
    loss_plus is loss_at of w
    w is w - 2 * h
    loss_minus is loss_at of w
    w is w + h
    grad is (loss_plus - loss_minus) / (2 * h)
    w is w - lr * grad
    steps is steps + 1
assert of [steps == 14, f"probe-write trajectory took {steps} steps"]
assert of [(when is w) == 57, f"probe-write trajectory recorded {when is w} observations"]
```

On this trajectory, the probed version stops after 14 updates with
`when is w` equal to 57. Compute probe values through a helper instead, so
only the real update writes `w`:

```eigenscript fragment
w is 0.0
lr is 0.05
h is 1e-4
loss_at is (c) => (14.0 / 3.0) * (c - 2.0) * (c - 2.0)
steps is 0
loop while not converged of w:
    grad is ((loss_at of (w + h)) - (loss_at of (w - h))) / (2 * h)
    w is w - lr * grad
    steps is steps + 1
assert of [steps == 21, f"helper trajectory took {steps} steps"]
assert of [(when is w) == 22, f"helper trajectory recorded {when is w} observations"]
```

The helper version takes 21 updates and `when is w` is 22: the initial
assignment plus one assignment per update. The runnable full-batch example is
[`examples/gradient_descent.eigs`](../examples/gradient_descent.eigs).

### Gentle, monotonic convergence

`loop while not converged` reads as the obvious convergence idiom, and
since #861 it is correct for any numeric value that actually settles —
subject to its finite-window tolerance and exact-int rules. What
remains worth knowing: the tolerance semantics (settled ≠ arrived), the
observation-cadence rule, and the divergent-input guard. Fence expectations below follow R3-STD; hosted doc-fence execution
checks the runtime results.

### A small step alone does not certify convergence

The Cauchy test measures the span of the whole window, rather than each
step separately. Twenty 0.05% decreases still span about 0.5% over the
last ten steps, so this trajectory remains `improving`:

```eigenscript
x is 100.0
for i in range of 20:
    x is x * 0.9995
print of (report of x)
```
```output
improving
```

A sufficiently slow unbounded drift can nevertheless fit a finite Cauchy
window. The residuals above state that limit. `unobserved:` does not alter
numeric sampling cadence: its numeric steps still enter the window.

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
    x is x * 0.7          # contracts toward a limit
print of (report of x)
```
```output
improving
```

```eigenscript
x is 1.0
for i in range of 13:
    x is x * 1.43         # non-vanishing same-sign steps
print of (report of x)
```
```output
diverging
```

Numeric `where` now returns the value itself, so `where is x` at `1.0`
is `1.0` without computing entropy. The entropy formula remains for numbers
inside containers and for non-numeric classification; its magnitude
symmetries remain properties of that separate signal. A numeric snapshot
refuses `classify of [t, "entropy"]` with `value`.

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
  the observer stall backstop. An iteration counts when the numeric subject's
  last relative step is quiet (`|r| < dh_zero`), OR its current value is
  non-finite OR its last step is non-finite (a step from or to a non-finite
  value), OR its window reads `diverging`, OR it reads `oscillating`
  with a non-contracting amplitude. The oscillation clause never counts a
  contracting amplitude; merely not converged never counts. The counter
  resets on every non-counting iteration. Non-finite current values or
  last steps count before any finite-amplitude test. The last step is the
  retained relative step that the quiet clause already reads, so its
  non-finiteness is a window fact even when the current value is finite.
  For the newest W+1 inputs (or available prefix), provided all are finite,
  compare the maximum absolute magnitude R of the recent floor(n/2)
  values with O of the older remainder: R >= O is non-contracting, R < O is
  contracting. A retained non-finite input does not establish this finite
  amplitude fact; the current-or-last-step non-finite clause still counts
  independently.
  This is a fact about the stored window, with exact integer
  and mixed comparisons, not a claim about a future limit. After 100 counted
  iterations the loop exits with `__loop_exit__ == "stalled"`
  (RULING R31-6 amends R31-4's non-finite clause; the alternation count band
  is 100..112 under R31-5). The **named** form deliberately does
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

- **Tolerance tighter than the fixed value.** `converged` tests the window diameter
  (`dh_zero`, fixed at 0.1% relative with an absolute floor). It is not configurable;
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
print of (a + " " + b)
```
```output
moving oscillating
```

A closure's initial `q is 0.0` is its first finite baseline and running
minimum. The positive decay never beats that minimum, so D2 does not call
it `improving`; its window is still moving after these 40 updates. The
second entity's own sign-flipping history reads `oscillating`.

A named binding per entity (`qa is fleet[0][2]`, `qb is fleet[1][2]`) is the
same thing when N is fixed at authoring time. Container-keyed trajectory
(dict fields and list elements carrying their own slot) is a ROADMAP item,
not a current capability.

## Cost

Numeric assignments perform O(1) value bookkeeping: checked displacement,
relative normalization, ring writes, an exact flag, and a running-best
update. They do not call the numeric entropy formula or maintain an
entropy-step ring. Predicate queries scan the fixed ten-step window.
Non-numeric entropy still costs the binding's own content size, plus bounded
comparison work. The observer gate can skip bookkeeping for a program that
has no observer or history readers; see [OBSERVER.md](OBSERVER.md#cost).

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
